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

	stdin, agentIn := io.Pipe()
	defer agentIn.Close()
	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	go run([]string{socket}, stdin, stdout, io.Discard)

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
	holdFor = 200 * time.Millisecond
	defer func() { holdFor = 30 * time.Second }()
	socket := shortSocket(t)
	listener := listen(t, socket)

	stdin, agentIn := io.Pipe()
	defer agentIn.Close()
	agentOut, stdout := io.Pipe()
	read := lines(agentOut)
	go run([]string{socket}, stdin, stdout, io.Discard)
	accept(t, listener).conn.Close()
	listener.Close()

	time.Sleep(100 * time.Millisecond)
	agentIn.Write([]byte(`{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n"))
	agentIn.Write([]byte(`{"jsonrpc":"2.0","id":"a","method":"ping"}` + "\n"))
	if got := next(t, read); !strings.Contains(got, `"id":"a","error"`) || !strings.Contains(got, "not reachable") {
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
