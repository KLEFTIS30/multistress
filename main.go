package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

type Tool struct {
	Name string
	Args []string
}

func streamOutput(name string, r io.Reader, wg *sync.WaitGroup) {
	defer wg.Done()
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fmt.Printf("[%-12s] %s\n", name, scanner.Text())
	}
}

func runTool(t Tool, wg *sync.WaitGroup) {
	defer wg.Done()

	cmd := exec.Command(t.Args[0], t.Args[1:]...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Printf("[%-12s] ERROR: %v\n", t.Name, err)
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		fmt.Printf("[%-12s] ERROR: %v\n", t.Name, err)
		return
	}

	if err := cmd.Start(); err != nil {
		fmt.Printf("[%-12s] FAILED TO START: %v\n", t.Name, err)
		return
	}

	var streamWg sync.WaitGroup
	streamWg.Add(2)
	go streamOutput(t.Name, stdout, &streamWg)
	go streamOutput(t.Name, stderr, &streamWg)
	streamWg.Wait()

	if err := cmd.Wait(); err != nil {
		fmt.Printf("[%-12s] EXIT: %v\n", t.Name, err)
	}
}

func main() {
	target := "https://homm.store"
	duration := "300s"

	tools := []Tool{
		{
			Name: "bombardier",
			Args: []string{"bombardier", "-c", "400", "-d", duration, "-t", "1500ms", "--http2", "--insecure", "-l", target},
		},
		{
			Name: "hey",
			Args: []string{"hey", "-c", "400", "-z", duration, "-t", "1.5", target},
		},
		{
			Name: "vegeta",
			Args: []string{"sh", "-c", fmt.Sprintf("echo 'GET %s' | vegeta attack -rate=0 -max-workers=400 -duration=%s -insecure | vegeta report", target, duration)},
		},
		{
			Name: "plow",
			Args: []string{"plow", "-c", "400", "-d", duration, "--insecure", target},
		},
	}

	fmt.Printf("=== MultiStress starting at %s ===\n", time.Now().Format("2006-01-02 15:04:05"))
	fmt.Printf("Target: %s | Duration: %s | Total workers: %d\n\n", target, duration, 1600)

	var wg sync.WaitGroup
	for _, t := range tools {
		wg.Add(1)
		go runTool(t, &wg)
	}

	wg.Wait()

	fmt.Printf("\n=== MultiStress finished at %s ===\n", time.Now().Format("2006-01-02 15:04:05"))
	os.Exit(0)
}
