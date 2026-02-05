from __future__ import annotations

import asyncio
import logging
from typing import Any

from .codex import CodexCommandError, CodexExecutor
from .db import ProjectRepository
from .indexer import IndexingService
from .planner import Planner
from .project_store import ProjectStore
from .skills import load_skill_bundle

logger = logging.getLogger(__name__)


class RunOrchestrator:
    def __init__(
        self,
        *,
        project_store: ProjectStore,
        indexer: IndexingService,
        planner: Planner,
        codex: CodexExecutor,
    ) -> None:
        self.project_store = project_store
        self.indexer = indexer
        self.planner = planner
        self.codex = codex
        self._tasks: dict[str, asyncio.Task[None]] = {}

    def _compose_planner_user_message(
        self,
        trigger_message: dict[str, Any],
        *,
        rag_hits: list[dict[str, Any]] | None = None,
    ) -> str:
        content = str(trigger_message.get("content", "")).strip()
        parts = trigger_message.get("parts") or []
        if not isinstance(parts, list):
            return content

        file_blocks: list[str] = []
        for part in parts:
            if not isinstance(part, dict):
                continue
            if str(part.get("type", "")) != "file_context":
                continue
            path = str(part.get("path", "")).strip()
            excerpt = str(part.get("excerpt", "")).strip()
            if not path and not excerpt:
                continue
            block = f"File: {path or '(unknown)'}\n{excerpt}" if excerpt else f"File: {path}"
            file_blocks.append(block[:5000])

        sections: list[str] = [content]
        if file_blocks:
            sections.append(
                "[Mentioned file context]\n"
                + "\n\n".join(file_blocks[:6])
                + "\n[/Mentioned file context]"
            )

        if rag_hits:
            rag_lines: list[str] = []
            for hit in rag_hits[:6]:
                path = str(hit.get("path_or_url") or hit.get("title") or "(unknown)")
                score = float(hit.get("score") or 0.0)
                excerpt = str(hit.get("text") or "").strip().replace("\r\n", "\n")
                if len(excerpt) > 800:
                    excerpt = excerpt[:800] + "... (truncated)"
                rag_lines.append(f"Path: {path}\nScore: {score:.3f}\nExcerpt:\n{excerpt}")
            if rag_lines:
                sections.append("[Indexed context]\n" + "\n\n".join(rag_lines) + "\n[/Indexed context]")

        return "\n\n".join(section for section in sections if section).strip()

    def start_run(self, *, project_id: str, conversation_id: str, trigger_message_id: str, mode: str) -> dict[str, Any]:
        context = self.project_store.get(project_id)
        if context is None:
            raise ValueError("Unknown project")

        repo = ProjectRepository(context)
        run = repo.create_run(conversation_id, trigger_message_id, mode=mode)

        task = asyncio.create_task(
            self._execute_run(
                project_id=project_id,
                conversation_id=conversation_id,
                run_id=run["id"],
                trigger_message_id=trigger_message_id,
            )
        )
        self._tasks[run["id"]] = task
        logger.info(
            "Run started run_id=%s project_id=%s conversation_id=%s mode=%s",
            run["id"],
            project_id,
            conversation_id,
            mode,
        )
        return run

    async def cancel_run(self, *, project_id: str, run_id: str) -> dict[str, Any] | None:
        context = self.project_store.get(project_id)
        if context is None:
            return None

        repo = ProjectRepository(context)
        run = repo.get_run(run_id)
        if run is None:
            return None

        task = self._tasks.get(run_id)
        if task and not task.done():
            task.cancel()
            with context.lock:
                repo.update_run(run_id, status="cancelled", finished=True)
                repo.add_event("run_cancelled", conversation_id=run["conversation_id"], run_id=run_id, payload={"reason": "user_request"})
            return repo.get_run(run_id)

        return run

    async def _execute_run(self, *, project_id: str, conversation_id: str, run_id: str, trigger_message_id: str) -> None:
        context = self.project_store.get(project_id)
        if context is None:
            return
        repo = ProjectRepository(context)

        try:
            with context.lock:
                repo.update_run(run_id, status="running")
                repo.add_event("run_started", conversation_id=conversation_id, run_id=run_id, payload={"trigger_message_id": trigger_message_id})

            trigger_msg = repo.get_message(conversation_id, trigger_message_id)
            if not trigger_msg:
                raise RuntimeError("Trigger message not found")

            history = repo.list_messages(conversation_id, cursor=None, limit=500)
            skills = load_skill_bundle(context.stash_dir)
            rag_hits: list[dict[str, Any]] = []
            try:
                self.indexer.scan_project_files(context, repo)
                rag_hits = self.indexer.search(
                    repo,
                    query=str(trigger_msg.get("content", ""))[:2000],
                    limit=8,
                )
            except Exception:
                logger.exception("RAG context preparation failed run_id=%s", run_id)

            planner_user_message = self._compose_planner_user_message(trigger_msg, rag_hits=rag_hits)
            plan = self.planner.plan(
                user_message=planner_user_message,
                conversation_history=history,
                skill_bundle=skills,
                project_summary=repo.project_view(),
            )
            logger.info(
                "Planner produced run_id=%s commands=%s",
                run_id,
                len(plan.commands),
            )
            with context.lock:
                repo.add_event(
                    "run_planned",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={
                        "command_count": len(plan.commands),
                        "rag_hit_count": len(rag_hits),
                        "rag_paths": [str(hit.get("path_or_url") or "") for hit in rag_hits[:6]],
                        "planner_preview": plan.planner_text[:1200],
                        "commands": [command.cmd for command in plan.commands[:12]],
                    },
                )

            tool_summaries: list[str] = []
            failures = 0

            if plan.commands:
                for step_index, command in enumerate(plan.commands, start=1):
                    with context.lock:
                        step_id = repo.create_run_step(
                            run_id,
                            step_index,
                            "codex_cmd",
                            {
                                "raw": command.raw,
                                "cmd": command.cmd,
                                "cwd": command.cwd,
                                "worktree": command.worktree,
                            },
                        )
                        repo.add_event(
                            "run_step_started",
                            conversation_id=conversation_id,
                            run_id=run_id,
                            payload={"step_id": step_id, "step_index": step_index},
                        )

                    try:
                        result = await asyncio.to_thread(self.codex.execute, context, command)
                        stderr_excerpt = ((result.stderr or "").strip().splitlines() or [""])[0][:240]
                        stdout_excerpt = ((result.stdout or "").strip().splitlines() or [""])[0][:240]
                        failure_detail = stderr_excerpt or stdout_excerpt
                        output = {
                            "engine": result.engine,
                            "exit_code": result.exit_code,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                            "cwd": result.cwd,
                            "worktree_path": result.worktree_path,
                            "started_at": result.started_at,
                            "finished_at": result.finished_at,
                        }
                        status = "completed" if result.exit_code == 0 else "failed"
                        if result.exit_code != 0:
                            failures += 1

                        with context.lock:
                            repo.finish_run_step(step_id, status=status, output_data=output)
                            event_payload: dict[str, Any] = {
                                "step_id": step_id,
                                "step_index": step_index,
                                "status": status,
                                "exit_code": result.exit_code,
                            }
                            if result.exit_code != 0 and failure_detail:
                                event_payload["detail"] = failure_detail
                            repo.add_event(
                                "run_step_completed",
                                conversation_id=conversation_id,
                                run_id=run_id,
                                payload=event_payload,
                            )
                            repo.create_message(
                                conversation_id,
                                role="tool",
                                content=(
                                    f"Executed command:\n{command.cmd}\n\n"
                                    f"exit_code={result.exit_code}\n"
                                    f"stdout:\n{(result.stdout or '').strip()[:4000]}\n\n"
                                    f"stderr:\n{(result.stderr or '').strip()[:2000]}"
                                ),
                                parts=[],
                                parent_message_id=trigger_message_id,
                                metadata={"run_id": run_id, "step_index": step_index},
                            )

                        summary = f"Step {step_index}: exit_code={result.exit_code}"
                        if result.exit_code != 0 and failure_detail:
                            summary += f" ({failure_detail})"
                        tool_summaries.append(summary)

                    except (CodexCommandError, RuntimeError) as exc:
                        failures += 1
                        with context.lock:
                            repo.finish_run_step(step_id, status="failed", error=str(exc))
                            repo.add_event(
                                "run_step_completed",
                                conversation_id=conversation_id,
                                run_id=run_id,
                                payload={"step_id": step_id, "step_index": step_index, "status": "failed", "error": str(exc)},
                            )
                        tool_summaries.append(f"Step {step_index}: failed ({exc})")

            assistant_content = plan.planner_text
            if tool_summaries:
                assistant_content += "\n\nExecution summary:\n- " + "\n- ".join(tool_summaries)

            with context.lock:
                final_message = repo.create_message(
                    conversation_id,
                    role="assistant",
                    content=assistant_content,
                    parts=[],
                    parent_message_id=trigger_message_id,
                    metadata={"run_id": run_id},
                )
                repo.add_event(
                    "message_finalized",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"message_id": final_message["id"]},
                )

                if failures:
                    repo.update_run(
                        run_id,
                        status="failed",
                        output_summary=f"{len(plan.commands)} step(s), {failures} failed",
                        error="One or more run steps failed",
                        finished=True,
                    )
                    repo.add_event(
                        "run_failed",
                        conversation_id=conversation_id,
                        run_id=run_id,
                        payload={"failures": failures},
                    )
                else:
                    repo.update_run(
                        run_id,
                        status="done",
                        output_summary=f"{len(plan.commands)} step(s) executed",
                        finished=True,
                    )
                    repo.add_event(
                        "run_completed",
                        conversation_id=conversation_id,
                        run_id=run_id,
                        payload={"steps": len(plan.commands)},
                    )

        except asyncio.CancelledError:
            with context.lock:
                repo.update_run(run_id, status="cancelled", finished=True)
                repo.add_event(
                    "run_cancelled",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"reason": "cancelled"},
                )
            raise
        except Exception as exc:
            with context.lock:
                repo.update_run(
                    run_id,
                    status="failed",
                    output_summary="Run crashed",
                    error=str(exc),
                    finished=True,
                )
                repo.add_event(
                    "run_failed",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"error": str(exc)},
                )
        finally:
            self._tasks.pop(run_id, None)
