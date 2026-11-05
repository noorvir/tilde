package main

import (
	"bufio"
	"bytes"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
)

// The proxy copies both ways: a line from the agent reaches the socket, and Tilde's answer
// reaches the agent; Tilde closing ends it with a failure.
func TestCopiesBothWays(t *testing.T) {
	socket := filepath.Join(t.TempDir(), "tilde.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	received := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		line, _ := bufio.NewReader(conn).ReadString('\n')
		received <- line
		conn.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}` + "\n"))
		conn.Close()
	}()

	stdin, agent := io.Pipe()
	defer agent.Close()
	go agent.Write([]byte(`{"jsonrpc":"2.0","id":1,"method":"ping"}` + "\n"))
	var stdout, stderr bytes.Buffer
	code := run([]string{socket}, stdin, &stdout, &stderr)

	if got := <-received; got != `{"jsonrpc":"2.0","id":1,"method":"ping"}`+"\n" {
		t.Errorf("Tilde got %q", got)
	}
	if got := stdout.String(); got != `{"jsonrpc":"2.0","id":1,"result":{}}`+"\n" {
		t.Errorf("the agent got %q", got)
	}
	if code != 1 || !strings.Contains(stderr.String(), "closed") {
		t.Errorf("exit %d, stderr %q", code, stderr.String())
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
