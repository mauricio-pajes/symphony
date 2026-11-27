package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type projectHealth struct {
	Name string
	Err  error
}

type projectSource struct {
	name   string
	client *daemonClient
}

type projectClient struct {
	sources []projectSource
}

func (c *projectClient) discoverLocal() {
	owner, err := user.Current()
	if err != nil {
		return
	}
	output, err := exec.Command("ps", "-ww", "-U", owner.Username, "-o", "args=").Output()
	if err != nil {
		return
	}
	ports := make(map[int]bool)
	names := make(map[string]bool)
	for command := range strings.SplitSeq(string(output), "\n") {
		executable, port, ok := daemonProcess(command)
		if !ok || ports[port] {
			continue
		}
		name := projectName(executable, port)
		if names[name] {
			name = fmt.Sprintf("%s (%d)", name, port)
		}
		if c.add(fmt.Sprintf("%s=http://127.0.0.1:%d", name, port)) == nil {
			ports[port], names[name] = true, true
		}
	}
}

const daemonAcknowledgement = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

func daemonProcess(command string) (string, int, bool) {
	executable, arguments, found := strings.Cut(strings.TrimSpace(command), " -")
	if !found || filepath.Base(executable) != "symphony" {
		return "", 0, false
	}
	args := strings.Fields("-" + arguments)
	var port int
	var acknowledged bool
	for index, value := range args {
		switch {
		case value == daemonAcknowledgement:
			acknowledged = true
		case value == "--port" && index+1 < len(args):
			port, _ = strconv.Atoi(args[index+1])
		case strings.HasPrefix(value, "--port="):
			port, _ = strconv.Atoi(strings.TrimPrefix(value, "--port="))
		}
	}
	return executable, port, acknowledged && port > 0 && port <= 65_535
}

func projectName(executable string, port int) string {
	directory := filepath.Dir(executable)
	if filepath.Base(directory) == "bin" && filepath.Base(filepath.Dir(directory)) == "elixir" {
		directory = filepath.Dir(filepath.Dir(directory))
	}
	labelPath := filepath.Join(directory, "console-project")
	if info, err := os.Lstat(labelPath); err == nil && info.Mode().IsRegular() && info.Size() <= 512 {
		if data, err := os.ReadFile(labelPath); err == nil {
			line, _, _ := strings.Cut(string(data), "\n")
			if label := clean(line); validProjectName(label) {
				return label
			}
		}
	}
	name := strings.TrimPrefix(filepath.Base(directory), "symphony-")
	name = clean(strings.ReplaceAll(strings.TrimSuffix(name, "-runtime"), "-", " "))
	if !validProjectName(name) {
		return fmt.Sprintf("Symphony %d", port)
	}
	return name
}

func validProjectName(name string) bool {
	return name != "" && len(name) <= 100 && name == clean(name) && !strings.Contains(name, "=")
}

func (c *projectClient) add(value string) error {
	name, address, found := strings.Cut(value, "=")
	if !found || !validProjectName(name) {
		return errors.New("use a project name followed by = and an HTTP loopback URL")
	}
	client, err := newDaemonClient(address)
	if err != nil {
		return err
	}
	for _, source := range c.sources {
		if name == source.name || client.baseURL.Host == source.client.baseURL.Host {
			return fmt.Errorf("duplicate project name or daemon address for %q", name)
		}
	}
	c.sources = append(c.sources, projectSource{name: name, client: client})
	return nil
}

func (c *projectClient) state(ctx context.Context) (snapshot, error) {
	type result struct {
		snapshot snapshot
		err      error
	}
	results := make([]result, len(c.sources))
	var pending sync.WaitGroup
	for index, source := range c.sources {
		pending.Go(func() {
			results[index].snapshot, results[index].err = source.client.state(ctx)
		})
	}
	pending.Wait()

	merged := snapshot{GeneratedAt: time.Now()}
	for index, source := range c.sources {
		state := results[index]
		merged.Projects = append(merged.Projects, projectHealth{Name: source.name, Err: state.err})
		merged.Running = append(merged.Running, namedTickets(source.name, state.snapshot.Running)...)
		merged.Retrying = append(merged.Retrying, namedTickets(source.name, state.snapshot.Retrying)...)
		merged.Blocked = append(merged.Blocked, namedTickets(source.name, state.snapshot.Blocked)...)
	}
	if len(results) == 1 {
		merged.CodexTotals = results[0].snapshot.CodexTotals
		merged.RateLimits = results[0].snapshot.RateLimits
	}
	return merged, nil
}

func namedTickets(name string, rows []ticket) []ticket {
	for index := range rows {
		rows[index].Project = name
	}
	return rows
}

func (c *projectClient) issue(ctx context.Context, key string) (ticketDetail, error) {
	name, id, found := strings.Cut(key, "\x00")
	if found {
		for _, source := range c.sources {
			if source.name == name {
				return source.client.issue(ctx, id)
			}
		}
	}
	return ticketDetail{}, errors.New("the ticket's project is unavailable")
}
