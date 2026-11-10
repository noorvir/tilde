// Command tproxy connects an agent's stdio MCP server to Tilde on the Mac. It copies lines
// between its standard input and output and the Unix socket that Tilde's ssh link forwards to
// this machine. When the link drops, it stays up for the agent and connects again to the same
// socket. Calls that Tilde had not answered get an error at once that says to call again; lines
// the agent writes while the link is down wait up to holdFor (at most maxHeld lines), then each
// request among them gets an error. Each connection starts with tproxy's own id, so that Tilde
// gives the agent back its MCP session. A new link puts a new socket at the path, so a missing or
// other file there is a drop too: the old connection may never see one when the Mac went away.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const version = "1.2.1"

var (
	holdFor    = 30 * time.Second
	maxHeld    = 100
	maxRetry   = 2 * time.Second
	watchEvery = time.Second
)

const (
	dropped     = "The link to Tilde dropped before Tilde answered. Call again; for wait_for_annotation, with the same session_id."
	unreachable = "Tilde is not reachable: the link to the Mac is down. Call again when Tilde runs and is linked."
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) > 1 {
		fmt.Fprintln(stderr, "usage: tproxy [socket] | --version")
		return 2
	}

	socket := filepath.Join(os.Getenv("HOME"), ".tilde", "tilde.sock")
	if len(args) == 1 {
		if args[0] == "--version" {
			fmt.Fprintln(stdout, version)
			return 0
		}
		socket = args[0]
	}

	conn, file, err := dial(socket)
	if err != nil {
		fmt.Fprintf(stderr, "tproxy: Tilde is not linked to this machine (%v). Open Tilde on the Mac.\n", err)
		return 1
	}

	agent := &agent{out: stdout}
	lines := make(chan []byte)
	go readLines(stdin, lines)
	id := make([]byte, 8)
	rand.Read(id)
	hello := []byte(`{"jsonrpc":"2.0","method":"tproxy/connect","params":{"id":"` + hex.EncodeToString(id) + `"}}` + "\n")

	var held []heldLine
	for {
		var closed bool
		closed, held = pipe(conn, socket, file, hello, held, lines, agent)
		if closed {
			return 0
		}

		// One timer for each try, so that input while the link is down never puts a try off.
		retry := 100 * time.Millisecond
		wait := time.NewTimer(retry)
		for conn = nil; conn == nil; {
			select {
			case line, ok := <-lines:
				if !ok {
					return 0
				}
				if len(held) >= maxHeld {
					agent.fail(line, unreachable)
				} else {
					held = append(held, heldLine{line, time.Now()})
				}
			case <-wait.C:
				for len(held) > 0 && time.Since(held[0].at) > holdFor {
					agent.fail(held[0].line, unreachable)
					held = held[1:]
				}
				conn, file, _ = dial(socket)
				retry = min(retry*2, maxRetry)
				wait.Reset(retry)
			}
		}
		wait.Stop()
	}
}

// dial connects to the socket and returns the file it was, which pipe watches.
func dial(socket string) (net.Conn, os.FileInfo, error) {
	file, err := os.Stat(socket)
	if err != nil {
		return nil, nil, err
	}
	conn, err := net.Dial("unix", socket)
	if err != nil {
		return nil, nil, err
	}
	return conn, file, nil
}

type heldLine struct {
	line []byte
	at   time.Time
}

// pipe sends the hello and the held lines, then copies lines both ways until the agent closes
// its input (true) or the link drops (false). On a drop, the calls Tilde has not answered get an
// error, and the held lines not yet written come back to be sent on the next connection.
func pipe(conn net.Conn, socket string, file os.FileInfo, hello []byte, held []heldLine, lines <-chan []byte, agent *agent) (bool, []heldLine) {
	defer conn.Close()

	open := &calls{ids: map[string][]byte{}}
	tildeDone := make(chan struct{})
	go func() {
		reader := bufio.NewReader(conn)
		for {
			line, err := reader.ReadBytes('\n')
			if err != nil {
				// A part of a line that the drop cut is not passed on: its call stays open.
				close(tildeDone)
				return
			}
			open.answered(line)
			agent.write(line)
		}
	}()

	// A line counts as open before it is written: a failed write may still have reached Tilde.
	send := func(line []byte) bool {
		open.add(line)
		_, err := conn.Write(line)
		return err == nil
	}
	sent := send(hello)
	for sent && len(held) > 0 {
		sent = send(held[0].line)
		held = held[1:]
	}

	watch := time.NewTicker(watchEvery)
	defer watch.Stop()
	for sent {
		select {
		case line, ok := <-lines:
			if !ok {
				return true, nil
			}
			sent = send(line)
		case <-tildeDone:
			sent = false
		case <-watch.C:
			now, err := os.Stat(socket)
			sent = err == nil && os.SameFile(file, now)
		}
	}

	conn.Close()
	<-tildeDone
	for _, line := range open.all() {
		agent.fail(line, dropped)
	}
	return false, held
}

func readLines(stdin io.Reader, lines chan<- []byte) {
	reader := bufio.NewReader(stdin)
	for {
		line, err := reader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			if line[len(line)-1] != '\n' {
				line = append(line, '\n')
			}
			lines <- line
		}
		if err != nil {
			close(lines)
			return
		}
	}
}

type message struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
}

// calls holds the requests sent to Tilde that it has not answered, by id.
type calls struct {
	mu  sync.Mutex
	ids map[string][]byte
}

func (c *calls) add(line []byte) {
	var m message
	if json.Unmarshal(line, &m) == nil && m.Method != "" && len(m.ID) > 0 && string(m.ID) != "null" {
		c.mu.Lock()
		c.ids[string(m.ID)] = line
		c.mu.Unlock()
	}
}

func (c *calls) answered(line []byte) {
	var m message
	if json.Unmarshal(line, &m) == nil && m.Method == "" {
		c.mu.Lock()
		delete(c.ids, string(m.ID))
		c.mu.Unlock()
	}
}

func (c *calls) all() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	var lines [][]byte
	for _, line := range c.ids {
		lines = append(lines, line)
	}
	return lines
}

// agent writes whole lines to the agent, one at a time.
type agent struct {
	mu  sync.Mutex
	out io.Writer
}

func (a *agent) write(line []byte) {
	a.mu.Lock()
	a.out.Write(line)
	a.mu.Unlock()
}

// fail answers a request with an error; a notification needs no answer.
func (a *agent) fail(line []byte, reason string) {
	var m message
	if json.Unmarshal(line, &m) != nil || len(m.ID) == 0 || string(m.ID) == "null" {
		return
	}
	text, _ := json.Marshal(reason)
	a.write([]byte(`{"jsonrpc":"2.0","id":` + string(m.ID) + `,"error":{"code":-32000,"message":` + string(text) + `}}` + "\n"))
}
