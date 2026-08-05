use std::io::{self, Read};
use std::process::ExitCode;

use destructive_git_guard::{inspect_hook_input, Decision};

const MAX_HOOK_INPUT_BYTES: u64 = 512 * 1024;

fn main() -> ExitCode {
    let mut input = String::new();
    let read_result = io::stdin()
        .take(MAX_HOOK_INPUT_BYTES + 1)
        .read_to_string(&mut input);

    let decision = match read_result {
        Ok(_) if input.len() as u64 <= MAX_HOOK_INPUT_BYTES => inspect_hook_input(&input),
        Ok(_) => Decision::FailClosed("hook input exceeds 512 KiB".to_string()),
        Err(error) => Decision::FailClosed(format!("failed to read hook input: {error}")),
    };

    match decision {
        Decision::Allow => ExitCode::SUCCESS,
        Decision::Block { segment } => {
            emit_block(&segment);
            ExitCode::from(2)
        }
        Decision::FailClosed(detail) => {
            emit_fail_closed(&detail);
            ExitCode::from(2)
        }
    }
}

fn emit_block(segment: &str) {
    let reason = format!(
        "[harness] 禁止直接执行受保护命令({segment})。rm、git push、stash 改写、工作树 \
         checkout/restore、破坏性 reset/clean/git rm 和 switch force-create 可能丢弃未暂存改动。"
    );
    emit_response(&reason);
    eprintln!("{reason}");
}

fn emit_fail_closed(detail: &str) {
    let reason = "[harness] destructive-git guard failed closed";
    emit_response(reason);
    eprintln!("{reason}: {detail}");
}

fn emit_response(reason: &str) {
    let response = serde_json::json!({
        "continue": false,
        "stopReason": reason,
    });
    println!("{response}");
}
