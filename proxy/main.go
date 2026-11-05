// Command tproxy connects an agent's stdio MCP server to Tilde on the Mac. It copies its
// standard input and output to the Unix socket that Tilde's ssh link forwards to this machine,
// until either side closes. It has no settings and reads nothing it copies.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
)

const version = "1.0.0"

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

	conn, err := net.Dial("unix", socket)
	if err != nil {
		fmt.Fprintf(stderr, "tproxy: Tilde is not linked to this machine (%v). Open Tilde on the Mac.\n", err)
		return 1
	}
	defer conn.Close()

	agentDone := make(chan struct{})
	tildeDone := make(chan struct{})
	go func() {
		io.Copy(conn, stdin)
		close(agentDone)
	}()
	go func() {
		io.Copy(stdout, conn)
		close(tildeDone)
	}()

	select {
	case <-agentDone:
		return 0
	case <-tildeDone:
		fmt.Fprintln(stderr, "tproxy: the link to Tilde closed")
		return 1
	}
}
