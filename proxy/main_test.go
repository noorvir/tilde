package main

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// tilde is one connection of the Mac's end of the link.
type tilde struct {
	conn   net.Conn
	reader *bufio.Reader
}

func accept(t *testing.T, listener net.Listener) *tilde {
	t.Helper()
	conn, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	return &tilde{conn, bufio.NewReader(conn)}
}

func (c *tilde) line(t *testing.T) string {
	t.Helper()
	line, err := c.reader.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	return line
}

// lines reads what tproxy writes to the agent.
func lines(output io.Reader) <-chan string {
	read := make(chan string, 16)
	go func() {
		reader := bufio.NewReader(output)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				close(read)
				return
			}
			read <- line
		}
	}()
	return read
}

func next(t *testing.T, read <-chan string) string {
	t.Helper()
	select {
	case line := <-read:
		return line
	case <-time.After(5 * time.Second):
		t.Fatal("no line for the agent")
		return ""
	}
}

// shortSocket is a socket path short enough for a socket address, which a test's temporary
// folder can pass.
func shortSocket(t *testing.T) string {
	t.Helper()
	folder, err := os.MkdirTemp("", "tp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(folder) })
	return filepath.Join(folder, "tilde.sock")
}

func listen(t *testing.T, socket string) net.Listener {
	t.Helper()
	os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	return listener
}

// start runs tproxy on the socket until the test ends, and returns the agent's end of its input.
func start(t *testing.T, socket string, stdout io.Writer) *io.PipeWriter {
	t.Helper()
	stdin, agentIn := io.Pipe()
	exit := make(chan int)
	go func() { exit <- run([]string{socket}, stdin, stdout, io.Discard) }()
	t.Cleanup(func() {
		agentIn.Close()
		<-exit
	})
	return agentIn
}

// set changes a setting for one test, after its tproxy has ended.
func set[T any](t *testing.T, setting *T, value T) {
	was := *setting
	*setting = value
	t.Cleanup(func() { *setting = was })
}

// Lines go both ways, each connection starts with tproxy's id, and the agent closing its
// input ends tproxy with success.
func TestCopiesBothWaysAfterItsID(t *testing.T) {
	socket := shortSocket(t)
	listener := listen(t, socket)
	defer listener.Close()

	stdin, agentIn := io.Pipe()
	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	exit := make(chan int)
	go func() { exit <- run([]string{socket}, stdin, stdout, io.Discard) }()

	mac := accept(t, listener)
	if hello := mac.line(t); !strings.Contains(hello, `"method":"tproxy/connect"`) {
		t.Errorf("first line %q", hello)
	}
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n"))
	if got := mac.line(t); got != `{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n" {
		t.Errorf("Tilde got %q", got)
	}
	mac.conn.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}` + "\n"))
	if got := next(t, read); got != `{"jsonrpc":"2.0","id":1,"result":{}}`+"\n" {
		t.Errorf("the agent got %q", got)
	}

	agentIn.Close()
	if code := <-exit; code != 0 {
		t.Errorf("exit %d", code)
	}
}

// A drop answers the open call with an error to call again; a line written while the link is
// down waits and reaches Tilde when it comes back, with the same id first.
func TestADropAnswersOpenCallsAndHoldsNewLines(t *testing.T) {
	socket := shortSocket(t)
	listener := listen(t, socket)

	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	agentIn := start(t, socket, stdout)

	first := accept(t, listener)
	hello := first.line(t)
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wait_for_annotation"}}` + "\n"))
	first.line(t)
	first.conn.Close()
	listener.Close()

	if got := next(t, read); !strings.Contains(got, `"id":2,"error"`) || !strings.Contains(got, "Call again") {
		t.Errorf("the cut call got %q", got)
	}

	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":3,"method":"ping"}` + "\n"))
	time.Sleep(300 * time.Millisecond)
	listener = listen(t, socket)
	defer listener.Close()
	second := accept(t, listener)
	if again := second.line(t); again != hello {
		t.Errorf("hello %q, then %q", hello, again)
	}
	if got := second.line(t); !strings.Contains(got, `"id":3`) {
		t.Errorf("Tilde got %q", got)
	}
	second.conn.Write([]byte(`{"jsonrpc":"2.0","id":3,"result":{}}` + "\n"))
	if got := next(t, read); !strings.Contains(got, `"id":3,"result"`) {
		t.Errorf("the agent got %q", got)
	}
}

// A request that waits too long for the link gets an error; a notification gets nothing.
func TestAHeldRequestTimesOut(t *testing.T) {
	set(t, &holdFor, 200*time.Millisecond)
	socket := shortSocket(t)
	listener := listen(t, socket)

	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	agentIn := start(t, socket, stdout)
	accept(t, listener).conn.Close()
	listener.Close()

	time.Sleep(100 * time.Millisecond)
	agentIn.Write([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n"))
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":"a","method":"ping"}` + "\n"))
	if got := next(t, read); !strings.Contains(got, `"id":"a","error"`) || !strings.Contains(got, "not reachable") {
		t.Errorf("the agent got %q", got)
	}
}

// failsWrite is a connection whose second write fails, as when the link drops again while
// tproxy sends what it held.
type failsWrite struct {
	net.Conn
	writes int
}

func (c *failsWrite) Write(b []byte) (int, error) {
	c.writes++
	if c.writes == 2 {
		return 0, io.ErrClosedPipe
	}
	return c.Conn.Write(b)
}

// A drop while the held lines are sent: the line being written may have reached Tilde, so it
// gets the error to call again; the lines after it stay held, with the time they came.
func TestASecondDropKeepsTheLinesNotSent(t *testing.T) {
	socket := shortSocket(t)
	listener := listen(t, socket)
	defer listener.Close()
	file, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	mac, near := net.Pipe()
	go io.Copy(io.Discard, mac)
	agentOut, stdout := io.Pipe()
	read := lines(agentOut)

	came := time.Now().Add(-time.Second)
	held := []heldLine{
		{[]byte(`{"jsonrpc":"2.0","id":"a","method":"ping"}` + "\n"), came},
		{[]byte(`{"jsonrpc":"2.0","id":"b","method":"ping"}` + "\n"), came},
		{[]byte(`{"jsonrpc":"2.0","id":"c","method":"ping"}` + "\n"), came},
	}
	closed, kept := pipe(&failsWrite{Conn: near}, socket, file, []byte("hello\n"), held, make(chan []byte), &agent{out: stdout})

	if closed || len(kept) != 2 || !strings.Contains(string(kept[0].line), `"b"`) || !strings.Contains(string(kept[1].line), `"c"`) || kept[0].at != came {
		t.Errorf("closed %v, kept %d lines", closed, len(kept))
	}
	if got := next(t, read); !strings.Contains(got, `"id":"a","error"`) || !strings.Contains(got, "Call again") {
		t.Errorf("the agent got %q", got)
	}
}

// Input while the link is down does not put off the next try to connect.
func TestInputDoesNotPutOffATry(t *testing.T) {
	set(t, &maxRetry, 200*time.Millisecond)
	socket := shortSocket(t)
	listener := listen(t, socket)

	agentIn := start(t, socket, io.Discard)
	accept(t, listener).conn.Close()
	listener.Close()

	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
				agentIn.Write([]byte(`{"jsonrpc":"2.0","method":"notifications/progress"}` + "\n"))
			}
		}
	}()
	time.Sleep(500 * time.Millisecond)

	listener = listen(t, socket)
	defer listener.Close()
	listener.(*net.UnixListener).SetDeadline(time.Now().Add(2 * time.Second))
	accept(t, listener)
}

// A link that comes back puts a new socket at the path, while the old connection may never
// see a drop: tproxy takes the new socket as a drop, and connects to it.
func TestANewSocketAtThePathIsADrop(t *testing.T) {
	set(t, &watchEvery, 50*time.Millisecond)
	socket := shortSocket(t)
	old := listen(t, socket)
	old.(*net.UnixListener).SetUnlinkOnClose(false)
	defer old.Close()

	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	agentIn := start(t, socket, stdout)
	first := accept(t, old)
	first.line(t)
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":4,"method":"tools/call"}` + "\n"))
	first.line(t)

	renewed := listen(t, socket+".new")
	defer renewed.Close()
	if err := os.Rename(socket+".new", socket); err != nil {
		t.Fatal(err)
	}
	if got := next(t, read); !strings.Contains(got, `"id":4,"error"`) || !strings.Contains(got, "Call again") {
		t.Errorf("the agent got %q", got)
	}
	second := accept(t, renewed)
	if hello := second.line(t); !strings.Contains(hello, "tproxy/connect") {
		t.Errorf("first line %q", hello)
	}
}

// A socket that is gone is a drop too.
func TestAMissingSocketIsADrop(t *testing.T) {
	set(t, &watchEvery, 50*time.Millisecond)
	socket := shortSocket(t)
	listener := listen(t, socket)
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	defer listener.Close()

	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	agentIn := start(t, socket, stdout)
	mac := accept(t, listener)
	mac.line(t)
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":5,"method":"tools/call"}` + "\n"))
	mac.line(t)

	os.Remove(socket)
	if got := next(t, read); !strings.Contains(got, `"id":5,"error"`) || !strings.Contains(got, "Call again") {
		t.Errorf("the agent got %q", got)
	}
}

func TestAMissingSocketFails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{filepath.Join(t.TempDir(), "none.sock")}, strings.NewReader(""), &stdout, &stderr)
	if code != 1 || strings.Count(stderr.String(), "\n") != 1 || !strings.Contains(stderr.String(), "not linked") {
		t.Errorf("exit %d, stderr %q", code, stderr.String())
	}
}

func TestVersion(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--version"}, strings.NewReader(""), &stdout, &stderr); code != 0 || stdout.String() != version+"\n" {
		t.Errorf("exit %d, stdout %q", code, stdout.String())
	}
}
