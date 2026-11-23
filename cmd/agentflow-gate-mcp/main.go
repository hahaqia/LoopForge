package main

import (
	"log"
	"os"
	"strconv"

	"agentflow/internal/gatemcp"
)

func main() {
	limit, _ := strconv.Atoi(os.Getenv("AGENTFLOW_ASK_LIMIT"))
	if err := gatemcp.RunWithLimits(os.Stdin, os.Stdout, os.Getenv("AGENTFLOW_GATE_RESULT_PATH"), os.Getenv("AGENTFLOW_ASK_PATH"), limit); err != nil {
		log.Fatal(err)
	}
}
