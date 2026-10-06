// Command dapsmoke debugs a program through a packaged lldb-dap the way Rune
// does: it starts the adapter with --connection listen://<addr>, dials it,
// launches the program, stops at a source breakpoint, and reads a local
// variable. It exits non-zero unless every step succeeds.
//
// Usage: go run ./scripts/dapsmoke -adapter <lldb-dap> -program <exe>
//
//	-source <file> -line <n> -var <name>=<value>
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type message struct {
	Seq        int             `json:"seq"`
	Type       string          `json:"type"`
	Command    string          `json:"command,omitempty"`
	Event      string          `json:"event,omitempty"`
	RequestSeq int             `json:"request_seq,omitempty"`
	Success    bool            `json:"success,omitempty"`
	Message    string          `json:"message,omitempty"`
	Arguments  any             `json:"arguments,omitempty"`
	Body       json.RawMessage `json:"body,omitempty"`
}

type client struct {
	conn net.Conn
	r    *bufio.Reader
	seq  int
	// pending maps request seq to command name.
	pending map[int]string
	verbose bool
}

func (c *client) send(command string, args any) {
	c.seq++
	c.pending[c.seq] = command
	b, err := json.Marshal(message{Seq: c.seq, Type: "request", Command: command, Arguments: args})
	if err != nil {
		fail("marshal %s: %v", command, err)
	}
	if c.verbose {
		fmt.Fprintf(os.Stderr, "--> %s\n", b)
	}
	if _, err := fmt.Fprintf(c.conn, "Content-Length: %d\r\n\r\n%s", len(b), b); err != nil {
		fail("send %s: %v", command, err)
	}
}

func (c *client) read() message {
	length := -1
	for {
		line, err := c.r.ReadString('\n')
		if err != nil {
			fail("read header: %v", err)
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
			length, err = strconv.Atoi(strings.TrimSpace(v))
			if err != nil {
				fail("bad header %q", line)
			}
		}
	}
	if length < 0 {
		fail("message without Content-Length")
	}
	b := make([]byte, length)
	if _, err := io.ReadFull(c.r, b); err != nil {
		fail("read body: %v", err)
	}
	var m message
	if err := json.Unmarshal(b, &m); err != nil {
		fail("unmarshal %s: %v", b, err)
	}
	if c.verbose {
		fmt.Fprintf(os.Stderr, "<-- %s\n", b)
	}
	if m.Type == "response" {
		m.Command = c.pending[m.RequestSeq]
	}
	return m
}

// adapter is the running lldb-dap. It leads its own process group so that
// killAdapter also reaps the debugserver and debuggee it spawns.
var adapter *exec.Cmd

// adapterOutput collects lldb-dap's stdout and stderr through a pipe owned by
// this process, so no orphan can keep the caller's terminal or pipes open.
var adapterOutput lockedBuffer

type lockedBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func killAdapter() {
	if adapter != nil && adapter.Process != nil {
		syscall.Kill(-adapter.Process.Pid, syscall.SIGKILL)
	}
}

// fail reports an error and exits. os.Exit skips deferred calls, so the
// adapter is killed here explicitly.
func fail(format string, args ...any) {
	killAdapter()
	fmt.Fprintf(os.Stderr, "dapsmoke: "+format+"\n", args...)
	if out := adapterOutput.String(); out != "" {
		fmt.Fprintf(os.Stderr, "lldb-dap output:\n%s", out)
	}
	os.Exit(1)
}

func main() {
	adapterPath := flag.String("adapter", "", "path to lldb-dap")
	program := flag.String("program", "", "program to debug")
	source := flag.String("source", "", "source file of the breakpoint")
	line := flag.Int("line", 0, "breakpoint line")
	variable := flag.String("var", "", "expected local at the breakpoint, as name=value")
	timeout := flag.Duration("timeout", 60*time.Second, "overall timeout")
	verbose := flag.Bool("v", false, "log every DAP message to stderr")
	flag.Parse()
	varName, varValue, ok := strings.Cut(*variable, "=")
	if *adapterPath == "" || *program == "" || *source == "" || *line == 0 || !ok {
		flag.Usage()
		os.Exit(2)
	}
	time.AfterFunc(*timeout, func() { fail("timed out after %v", *timeout) })

	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fail("pick port: %v", err)
	}
	addr := l.Addr().String()
	l.Close()

	adapter = exec.Command(*adapterPath, "--connection", "listen://"+addr)
	adapter.Stdout = &adapterOutput
	adapter.Stderr = &adapterOutput
	adapter.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := adapter.Start(); err != nil {
		fail("start %s: %v", *adapterPath, err)
	}
	exited := make(chan error, 1)
	go func() { exited <- adapter.Wait() }()
	defer killAdapter()

	var conn net.Conn
	for conn == nil {
		select {
		case err := <-exited:
			fail("lldb-dap exited before accepting a connection: %v", err)
		default:
		}
		if conn, err = net.Dial("tcp", addr); err != nil {
			time.Sleep(100 * time.Millisecond)
		}
	}
	c := &client{conn: conn, r: bufio.NewReader(conn), pending: map[int]string{}, verbose: *verbose}

	// lldb-dap matches breakpoint paths verbatim against the debug info, so
	// build the program in a directory without symlinks in its path: zig
	// records resolved paths, while clang keeps $PWD.
	src, err := filepath.Abs(*source)
	if err != nil {
		fail("%v", err)
	}
	prog, err := filepath.Abs(*program)
	if err != nil {
		fail("%v", err)
	}
	c.send("initialize", map[string]any{
		"clientID": "dapsmoke", "adapterID": "lldb", "pathFormat": "path",
		"linesStartAt1": true, "columnsStartAt1": true,
	})
	// Mirrors the launch request in config.yaml.
	c.send("launch", map[string]any{"program": prog, "stopOnEntry": false})

	// passed is set once the variable checks out; the exited and terminated
	// events that follow our own disconnect are then expected.
	passed := false
	for {
		m := c.read()
		if m.Type == "response" && !m.Success {
			fail("%s failed: %s %s", m.Command, m.Message, m.Body)
		}
		switch {
		case m.Type == "event" && m.Event == "initialized":
			c.send("setBreakpoints", map[string]any{
				"source":      map[string]any{"path": src},
				"breakpoints": []map[string]any{{"line": *line}},
			})
			c.send("configurationDone", nil)
		case m.Type == "event" && (m.Event == "exited" || m.Event == "terminated") && !passed:
			fail("program %s before stopping at %s:%d", m.Event, src, *line)
		case m.Type == "event" && m.Event == "stopped":
			var body struct {
				Reason   string `json:"reason"`
				ThreadID int    `json:"threadId"`
			}
			json.Unmarshal(m.Body, &body)
			if body.Reason != "breakpoint" {
				fail("stopped for %q, want breakpoint", body.Reason)
			}
			c.send("stackTrace", map[string]any{"threadId": body.ThreadID, "levels": 1})
		case m.Type == "response" && m.Command == "stackTrace":
			var body struct {
				StackFrames []struct {
					ID     int    `json:"id"`
					Name   string `json:"name"`
					Line   int    `json:"line"`
					Source struct {
						Path string `json:"path"`
					} `json:"source"`
				} `json:"stackFrames"`
			}
			json.Unmarshal(m.Body, &body)
			if len(body.StackFrames) == 0 {
				fail("empty stack trace")
			}
			f := body.StackFrames[0]
			if filepath.Base(f.Source.Path) != filepath.Base(src) || f.Line != *line {
				fail("stopped in %s at %s:%d, want %s:%d", f.Name, f.Source.Path, f.Line, src, *line)
			}
			c.send("scopes", map[string]any{"frameId": f.ID})
		case m.Type == "response" && m.Command == "scopes":
			var body struct {
				Scopes []struct {
					Name string `json:"name"`
					Ref  int    `json:"variablesReference"`
				} `json:"scopes"`
			}
			json.Unmarshal(m.Body, &body)
			for _, s := range body.Scopes {
				if s.Name == "Locals" {
					c.send("variables", map[string]any{"variablesReference": s.Ref})
				}
			}
		case m.Type == "response" && m.Command == "variables":
			var body struct {
				Variables []struct {
					Name  string `json:"name"`
					Value string `json:"value"`
				} `json:"variables"`
			}
			json.Unmarshal(m.Body, &body)
			for _, v := range body.Variables {
				if v.Name == varName {
					if v.Value != varValue {
						fail("%s = %s, want %s", varName, v.Value, varValue)
					}
					fmt.Printf("stopped at %s:%d with %s = %s\n", filepath.Base(src), *line, varName, v.Value)
					passed = true
					c.send("disconnect", map[string]any{"terminateDebuggee": true})
				}
			}
			if !passed {
				fail("no local %q at %s:%d; locals: %s", varName, src, *line, m.Body)
			}
		case m.Type == "response" && m.Command == "disconnect":
			return
		}
	}
}
