package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"agentflow/internal/domain"
	"agentflow/internal/runtime"
)

const (
	gateResultArtifactName = "__agentflow_gate_result"
	gateMissingRetryMarker = "__agentflow_missing_gate_result__"
	// maxAskQuestions 限制单个节点向人提问的总次数，避免 Agent 用提问代替判断。
	maxAskQuestions = 3
)

type verificationRun struct {
	gate      domain.VerificationGate
	onFailure string
}

func gateResultPath(nodeID string, attempt int) string {
	return filepath.ToSlash(filepath.Join(".agentflow", "gate-results", safeRunnerPath(nodeID), fmt.Sprintf("attempt-%d.json", attempt)))
}

func gateResultContract(path string) domain.ArtifactContract {
	return domain.ArtifactContract{Name: gateResultArtifactName, Path: path, MediaType: "application/json", Required: false}
}

func clearGateResult(workspace, path string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	err := os.RemoveAll(filepath.Join(workspace, filepath.FromSlash(path)))
	if askPath := runtime.GateAskPath(path); askPath != "" {
		if askErr := os.RemoveAll(filepath.Join(workspace, filepath.FromSlash(askPath))); askErr != nil && err == nil {
			err = askErr
		}
	}
	return err
}

type askQuestionPayload struct {
	ID       string   `json:"id"`
	Question string   `json:"question"`
	Options  []string `json:"options"`
	FreeText bool     `json:"freeText"`
}

type askPayload struct {
	Summary   string               `json:"summary"`
	Questions []askQuestionPayload `json:"questions"`
}

// readAskResultFrom 把 ask_human 的提问映射成一次 human 终态：节点停在
// waiting_approval 等操作员回答，回答后按 retry 继续（会续上同一 CLI 会话）。
// 问题文本写进 ActionRequired，前端现有的人工确认卡片可以直接展示。
func readAskResultFrom(outputs nodeOutputs, path string) (*domain.GateResult, []domain.PendingQuestion, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil, nil
	}
	raw, err := outputs.readFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	var ask askPayload
	if err := json.Unmarshal(raw, &ask); err != nil {
		return nil, nil, fmt.Errorf("ask_human payload is invalid: %w", err)
	}
	questions := make([]domain.PendingQuestion, 0, len(ask.Questions))
	for _, q := range ask.Questions {
		question := strings.TrimSpace(q.Question)
		if question == "" {
			continue
		}
		item := domain.PendingQuestion{ID: strings.TrimSpace(q.ID), Question: question, Options: q.Options, FreeText: q.FreeText}
		if item.ID == "" {
			item.ID = fmt.Sprintf("q%d", len(questions)+1)
		}
		if len(item.Options) == 0 {
			item.FreeText = true
		}
		questions = append(questions, item)
	}
	if len(questions) == 0 {
		return nil, nil, nil
	}
	var b strings.Builder
	for i, q := range questions {
		if i > 0 {
			b.WriteString("\n")
		}
		fmt.Fprintf(&b, "%d. %s", i+1, q.Question)
		if len(q.Options) > 0 {
			b.WriteString("（可选：" + strings.Join(q.Options, " / ") + "）")
		} else {
			b.WriteString("（请填写）")
		}
	}
	required := strings.TrimSpace(b.String())
	if len(required) > 4000 {
		required = required[:4000]
	}
	reason := strings.TrimSpace(ask.Summary)
	if reason == "" {
		reason = "Agent 需要确认后才能继续"
	}
	if len(reason) > 4000 {
		reason = reason[:4000]
	}
	return &domain.GateResult{Decision: "human", Reason: reason, ActionRequired: required}, questions, nil
}

func readGateResult(workspace, path string) (*domain.GateResult, error) {
	return readGateResultFrom(workspaceOutputs(workspace), path)
}

func readGateResultFrom(outputs nodeOutputs, path string) (*domain.GateResult, error) {
	raw, err := outputs.readFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var result domain.GateResult
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("submit_gate_result payload is invalid: %w", err)
	}
	result.Decision = strings.ToLower(strings.TrimSpace(result.Decision))
	result.Reason = strings.TrimSpace(result.Reason)
	result.ActionRequired = strings.TrimSpace(result.ActionRequired)
	result.Summary = strings.TrimSpace(result.Summary)
	switch result.Decision {
	case "pass", "rework", "fail", "human":
	default:
		return nil, fmt.Errorf("submit_gate_result decision %q is invalid", result.Decision)
	}
	if result.Reason == "" {
		return nil, fmt.Errorf("submit_gate_result reason is required")
	}
	if result.Decision == "human" && result.ActionRequired == "" {
		return nil, fmt.Errorf("submit_gate_result actionRequired is required for human decisions")
	}
	if len(result.Reason) > 4000 || len(result.ActionRequired) > 4000 || len(result.Summary) > 4000 || len(result.Findings) > 50 {
		return nil, fmt.Errorf("submit_gate_result exceeds size limits")
	}
	for _, finding := range result.Findings {
		if strings.TrimSpace(finding.Title) == "" || len(finding.Title) > 500 || len(finding.Severity) > 64 || len(finding.Evidence) > 4000 {
			return nil, fmt.Errorf("submit_gate_result contains an invalid finding")
		}
	}
	return &result, nil
}

// applyGateResult maps an Agent terminal decision onto the engine's failure
// pipeline. rejectTarget is the node's configured RejectTo: a rework decision
// without a valid reject target cannot be routed upstream, so it degrades to a
// terminal fail instead of failing with a misleading "upstream rework" error.
func applyGateResult(result *domain.GateResult, rejectTarget string) (error, string, bool) {
	if result == nil {
		return nil, "", false
	}
	switch result.Decision {
	case "pass":
		return nil, "", false
	case "rework":
		if strings.TrimSpace(rejectTarget) == "" {
			return fmt.Errorf("agent requested rework but this node has no rework target (rejectTo); treated as fail: %s", result.Reason), "fail", false
		}
		return fmt.Errorf("agent requested upstream rework: %s", result.Reason), "reject", true
	case "fail":
		return fmt.Errorf("agent submitted terminal failure: %s", result.Reason), "fail", false
	case "human":
		return fmt.Errorf("agent requested human confirmation: %s", result.Reason), "human", false
	default:
		return fmt.Errorf("unsupported agent terminal decision %q", result.Decision), "fail", false
	}
}

func appendSubmitGateInstruction(prompt, rejectTarget string, allowAsk, retry bool) string {
	if retry {
		return "刚才没有收到有效的节点终态。不要重复执行任务，也不要只输出文字；请立刻调用 submit_gate_result，提交 pass、rework、fail 或 human 之一以及具体 reason。选择 human 时还必须填写 actionRequired，明确需要人工确认什么。只有工具调用成功才算完成本节点。"
	}
	reworkInstruction := "- rework：存在应由上游节点返工的问题；平台会自动打回该节点；"
	if strings.TrimSpace(rejectTarget) == "" {
		reworkInstruction = "- rework：本节点没有配置返工目标，不可选择；需要直接终止时请选择 fail；"
	} else {
		reworkInstruction = fmt.Sprintf("- rework：存在应由上游节点「%s」返工的问题；平台会自动打回；", rejectTarget)
	}
	askSection := ""
	if allowAsk {
		askSection = `

# 可以先向人确认

如果需求、范围或方案上存在**必须由人决定**的歧义（例如目标用户、验收口径、取舍），先调用 MCP 工具 ask_human 提交 1-10 个具体问题：带两个以上选项的会渲染成选择题，不带选项的按开放填写。本节点会暂停等待回答，回答后你在同一会话里继续，不需要从头重做。不要用它询问你自己能查证的事实，也不要为了少做判断而滥用。`
	}
	return strings.TrimRight(prompt, "\n") + askSection + fmt.Sprintf(`

# 必须提交节点终态

完成任务后必须调用 MCP 工具 submit_gate_result，提交唯一终态：
- pass：任务正常完成；平台会自动流转到下游节点；
%s
- fail：本节点无法完成或出现不可恢复错误；平台会直接标记失败，不打回上游；
- human：无法可靠自动判断，或必须由人决策；平台会暂停并等待人工确认，此时 actionRequired 必填，必须明确说明需要人确认或决定什么。

必须根据当前真实情况选择，不要把 fail 当成 rework，也不要用 human 掩盖明确失败。reason 必须解释作出该终态的事实依据；rework 可用 actionRequired 写清返工要求；可附带 findings 和 evidence。不要用报告文本或最终回复代替工具调用。只有该工具调用成功，本节点才算完成。`, reworkInstruction)
}
