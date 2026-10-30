// Command intellisense is the agent-neutral governance CLI. See `intellisense help`.
package main

import (
	"os"

	"github.com/soupler-oss/intellisense/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
