use agent_shell_parser::parse::{
    default_command_config, parse_with_substitutions, Operator, ParsedPipeline, ShellSegment, Word,
    WrapperSpec,
};
use serde::de::{self, IgnoredAny, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::fmt;
use tree_sitter::{Node, Parser};

const MAX_DEPTH: usize = 32;
const MAX_PARSE_CALLS: usize = 128;
const MAX_SCRIPT_BYTES: usize = 64 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Block { segment: String },
    FailClosed(String),
}

struct HookInput {
    tool_inputs: Vec<ToolInput>,
}

#[derive(Deserialize)]
struct ToolInput {
    command: String,
}

impl<'de> Deserialize<'de> for HookInput {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserializer.deserialize_map(HookInputVisitor)
    }
}

struct HookInputVisitor;

impl<'de> Visitor<'de> for HookInputVisitor {
    type Value = HookInput;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a hook input object")
    }

    fn visit_map<M>(self, mut map: M) -> Result<Self::Value, M::Error>
    where
        M: MapAccess<'de>,
    {
        let mut tool_inputs = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            match key.as_str() {
                // JSON permits duplicate object keys. Inspect every command rather
                // than accepting last-wins behavior at this security boundary.
                "tool_input" | "toolInput" => tool_inputs.push(map.next_value()?),
                _ => {
                    map.next_value::<IgnoredAny>()?;
                }
            }
        }
        if tool_inputs.is_empty() {
            return Err(de::Error::missing_field("tool_input"));
        }
        Ok(HookInput { tool_inputs })
    }
}

pub fn inspect_hook_input(input: &str) -> Decision {
    let hook: HookInput = match serde_json::from_str(input) {
        Ok(hook) => hook,
        Err(error) => return Decision::FailClosed(format!("invalid hook input: {error}")),
    };
    for tool_input in hook.tool_inputs {
        let decision = inspect_command(&tool_input.command);
        if decision != Decision::Allow {
            return decision;
        }
    }
    Decision::Allow
}

pub fn inspect_command(command: &str) -> Decision {
    let mut inspector = match Inspector::new() {
        Ok(inspector) => inspector,
        Err(error) => return Decision::FailClosed(error),
    };
    match inspector.inspect_script(command, 0) {
        Ok(Some(segment)) => Decision::Block { segment },
        Ok(None) => Decision::Allow,
        Err(error) => Decision::FailClosed(error),
    }
}

struct Inspector {
    parser: Parser,
    parse_calls: usize,
}

impl Inspector {
    fn new() -> Result<Self, String> {
        let mut parser = Parser::new();
        parser
            .set_language(&tree_sitter_bash::LANGUAGE.into())
            .map_err(|error| format!("failed to load Bash grammar: {error}"))?;
        Ok(Self {
            parser,
            parse_calls: 0,
        })
    }

    fn inspect_script(&mut self, script: &str, depth: usize) -> Result<Option<String>, String> {
        self.inspect_script_with_stdin(script, depth, false)
    }

    fn inspect_script_with_stdin(
        &mut self,
        script: &str,
        depth: usize,
        inherited_stdin: bool,
    ) -> Result<Option<String>, String> {
        if script.len() > MAX_SCRIPT_BYTES {
            return Err("shell input exceeds 64 KiB".to_string());
        }
        if depth >= MAX_DEPTH {
            return Err("shell wrapper nesting exceeds 32 levels".to_string());
        }
        if self.parse_calls >= MAX_PARSE_CALLS {
            return Err("shell parse budget exceeded".to_string());
        }
        self.parse_calls += 1;

        let inputs = self.collect_shell_inputs(script)?;
        let pipeline = parse_with_substitutions(script)
            .map_err(|error| format!("Bash parser failed: {error}"))?;
        if pipeline.has_parse_errors_recursive() {
            return Err("Bash parser reported incomplete syntax".to_string());
        }
        self.inspect_pipeline(&pipeline, depth, &inputs, inherited_stdin)
    }

    fn inspect_pipeline(
        &mut self,
        pipeline: &ParsedPipeline,
        depth: usize,
        inputs: &[ShellInput],
        inherited_stdin: bool,
    ) -> Result<Option<String>, String> {
        for substitution in &pipeline.structural_substitutions {
            if let Some(blocked) =
                self.inspect_pipeline(&substitution.pipeline, depth, inputs, inherited_stdin)?
            {
                return Ok(Some(blocked));
            }
        }

        for (index, segment) in pipeline.segments.iter().enumerate() {
            for substitution in &segment.substitutions {
                if let Some(blocked) =
                    self.inspect_pipeline(&substitution.pipeline, depth, inputs, inherited_stdin)?
                {
                    return Ok(Some(blocked));
                }
            }
            let piped_input = inherited_stdin
                || (index > 0
                    && matches!(
                        pipeline.operators.get(index - 1),
                        Some(Operator::Pipe | Operator::PipeErr)
                    ));
            if let Some(blocked) = self.inspect_segment(segment, depth, piped_input, inputs)? {
                return Ok(Some(blocked));
            }
        }
        Ok(None)
    }

    fn inspect_segment(
        &mut self,
        segment: &ShellSegment,
        depth: usize,
        piped_input: bool,
        inputs: &[ShellInput],
    ) -> Result<Option<String>, String> {
        let mut words = semantic_words(segment);
        if let Some(assignment_count) = self.leading_assignment_count(&segment.command) {
            words.drain(..assignment_count.min(words.len()));
        } else {
            let first_command = words
                .iter()
                .position(|word| !word.is_assignment())
                .unwrap_or(words.len());
            words.drain(..first_command);
        }
        if words.is_empty() {
            return Ok(None);
        }

        let ansi_c_word = segment.command.contains("$'");
        let mut runtime_appended = false;
        let config = default_command_config();
        for _ in 0..MAX_DEPTH {
            let base = basename(control_value(&words[0], ansi_c_word)?);

            if base == "coproc" {
                return Err("coproc executes a command that cannot be inspected".to_string());
            }

            if base == "rtk" {
                match self.inspect_rtk(&words, depth, ansi_c_word)? {
                    RtkResult::Done(Some(blocked)) => return Ok(Some(blocked)),
                    RtkResult::Done(None) if runtime_appended => {
                        return Err(
                            "rtk receives runtime arguments that cannot be inspected".to_string()
                        );
                    }
                    RtkResult::Done(None) => return Ok(None),
                    RtkResult::Inner(inner) => {
                        words = inner;
                        continue;
                    }
                }
            }

            if base == "trap" {
                return self.inspect_trap(&words, depth, ansi_c_word);
            }
            if base == "command" && is_command_query(&words, ansi_c_word)? {
                return Ok(None);
            }

            if let Some(spec) = config.wrappers.iter().find(|spec| spec.name == base) {
                let inner = strip_wrapper(spec, &words)?;
                let wrapper_end = words.len().saturating_sub(inner.len());
                if spec.unanalyzable_flags.iter().any(|flag| {
                    words[1..wrapper_end]
                        .iter()
                        .any(|word| word_matches_flag(word.as_str(), flag))
                }) {
                    return Err(format!(
                        "wrapper {} uses an opaque execution flag",
                        spec.name
                    ));
                }
                if base == "watch" {
                    if runtime_appended {
                        return Err(
                            "watch receives runtime arguments that cannot be inspected".to_string()
                        );
                    }
                    return self.inspect_joined_script(&inner, depth, ansi_c_word);
                }
                if base == "parallel" {
                    if runtime_appended {
                        return Err(
                            "parallel receives runtime arguments that cannot be inspected"
                                .to_string(),
                        );
                    }
                    if inner.is_empty() {
                        return Ok(None);
                    }
                    return Err(
                        "parallel builds commands from input that cannot be inspected".to_string(),
                    );
                }
                if base == "xargs" && has_xargs_replace_flag(&words[1..wrapper_end], ansi_c_word)? {
                    return Err(
                        "xargs builds commands from replacement input that cannot be inspected"
                            .to_string(),
                    );
                }
                if base == "xargs" {
                    if inner.is_empty() {
                        if runtime_appended {
                            return Err(
                                "nested xargs receives runtime arguments that cannot be inspected"
                                    .to_string(),
                            );
                        }
                        return Ok(None);
                    }
                    runtime_appended = true;
                }
                words = inner;
                if words.is_empty() {
                    if runtime_appended {
                        return Err(format!(
                            "wrapper {base} receives runtime arguments that cannot be inspected"
                        ));
                    }
                    return Ok(None);
                }
                continue;
            }

            if config.shells.iter().any(|shell| shell == &base) {
                let input = inputs
                    .iter()
                    .filter(|input| input.applies_to(segment.command.trim()))
                    .fold(ShellInput::default(), |mut combined, input| {
                        combined.bodies.extend(input.bodies.iter().cloned());
                        combined.uninspectable_input |= input.uninspectable_input;
                        combined
                    });
                return self.inspect_shell(
                    &words,
                    depth,
                    ansi_c_word,
                    piped_input || runtime_appended,
                    &input,
                );
            }
            if config.eval_commands.iter().any(|command| command == &base) {
                if runtime_appended {
                    return Err(
                        "eval receives runtime arguments that cannot be inspected".to_string()
                    );
                }
                return self.inspect_joined_script(&words[1..], depth, ansi_c_word);
            }
            if config
                .source_commands
                .iter()
                .any(|command| command == &base)
            {
                return Err(format!(
                    "{base} reads command text from a file that cannot be inspected"
                ));
            }
            if runtime_appended
                && base == "git"
                && !is_runtime_git_command_safe(&words, ansi_c_word)?
            {
                if is_blocked_command(&words, ansi_c_word)? {
                    return Ok(Some(segment.command.clone()));
                }
                return Err("git receives runtime arguments that cannot be inspected".to_string());
            }
            if is_blocked_command(&words, ansi_c_word)? {
                return Ok(Some(segment.command.clone()));
            }
            return Ok(None);
        }
        Err("command wrapper nesting exceeds 32 levels".to_string())
    }

    fn inspect_trap(
        &mut self,
        words: &[Word],
        depth: usize,
        ansi_c_word: bool,
    ) -> Result<Option<String>, String> {
        let Some(action) = words.get(1) else {
            return Ok(None);
        };
        let action = control_value(action, ansi_c_word)?;
        if matches!(action.as_str(), "-" | "-p" | "--list" | "") {
            return Ok(None);
        }
        if action == "--" {
            let action = words
                .get(2)
                .ok_or_else(|| "trap -- is missing its action".to_string())?;
            let action = control_value(action, ansi_c_word)?;
            if action == "-" || action.is_empty() {
                return Ok(None);
            }
            return self.inspect_script(&action, depth + 1);
        }
        self.inspect_script(&action, depth + 1)
    }

    fn inspect_rtk(
        &mut self,
        words: &[Word],
        depth: usize,
        ansi_c_word: bool,
    ) -> Result<RtkResult, String> {
        let mut index = 1;
        while let Some(word) = words.get(index) {
            let value = control_value(word, ansi_c_word)?;
            match value.as_str() {
                "--" => {
                    index += 1;
                    break;
                }
                "--version" | "-V" | "--help" | "-h" => {
                    return Ok(RtkResult::Done(None));
                }
                "--ultra-compact" | "--skip-env" | "--verbose" => index += 1,
                flag if flag.starts_with('-')
                    && flag.len() > 1
                    && flag[1..].chars().all(|character| character == 'v') =>
                {
                    index += 1
                }
                flag if flag.starts_with('-') => {
                    return Err(format!("unsupported rtk option: {flag}"));
                }
                _ => break,
            }
        }

        let Some(mode_word) = words.get(index) else {
            return Ok(RtkResult::Done(None));
        };
        let mode = control_value(mode_word, ansi_c_word)?;
        if mode == "run" {
            return Ok(RtkResult::Done(self.inspect_rtk_run(
                &words[index + 1..],
                depth,
                ansi_c_word,
            )?));
        }

        if matches!(mode.as_str(), "proxy" | "err" | "summary" | "test") {
            index += 1;
            while let Some(word) = words.get(index) {
                match control_value(word, ansi_c_word)?.as_str() {
                    "--ultra-compact" | "--skip-env" => index += 1,
                    "-h" | "--help" => return Ok(RtkResult::Done(None)),
                    "--" => {
                        index += 1;
                        break;
                    }
                    value if value.starts_with('-') => {
                        return Err(format!("unsupported rtk {mode} option: {value}"));
                    }
                    _ => break,
                }
            }
        }

        if index >= words.len() {
            Ok(RtkResult::Done(None))
        } else {
            Ok(RtkResult::Inner(words[index..].to_vec()))
        }
    }

    fn inspect_rtk_run(
        &mut self,
        words: &[Word],
        depth: usize,
        ansi_c_word: bool,
    ) -> Result<Option<String>, String> {
        let mut index = 0;
        while let Some(word) = words.get(index) {
            let value = control_value(word, ansi_c_word)?;
            match value.as_str() {
                "-c" | "--command" => {
                    let script = words
                        .get(index + 1)
                        .ok_or_else(|| "rtk run command option is missing its value".to_string())?;
                    return self.inspect_script(&control_value(script, ansi_c_word)?, depth + 1);
                }
                option if option.starts_with("--command=") => {
                    return self.inspect_script(
                        option.split_once('=').map(|(_, value)| value).unwrap_or(""),
                        depth + 1,
                    );
                }
                "--ultra-compact" | "--skip-env" => index += 1,
                "-h" | "--help" => return Ok(None),
                "--" => {
                    index += 1;
                    break;
                }
                option if option.starts_with('-') => {
                    return Err(format!("unsupported rtk run option: {option}"));
                }
                _ => break,
            }
        }

        let mut parts = Vec::new();
        for word in &words[index..] {
            let part = control_value(word, ansi_c_word)?;
            if let Some(blocked) = self.inspect_script(&part, depth + 1)? {
                return Ok(Some(blocked));
            }
            parts.push(part);
        }
        self.inspect_script(&parts.join(" "), depth + 1)
    }

    fn inspect_joined_script(
        &mut self,
        words: &[Word],
        depth: usize,
        ansi_c_word: bool,
    ) -> Result<Option<String>, String> {
        let parts = words
            .iter()
            .map(|word| control_value(word, ansi_c_word))
            .collect::<Result<Vec<_>, _>>()?;
        if parts.is_empty() {
            Ok(None)
        } else {
            self.inspect_script(&parts.join(" "), depth + 1)
        }
    }

    fn inspect_shell(
        &mut self,
        words: &[Word],
        depth: usize,
        ansi_c_word: bool,
        piped_input: bool,
        input: &ShellInput,
    ) -> Result<Option<String>, String> {
        let mut index = 1;
        let mut reads_stdin = false;
        let mut command_string = false;

        while let Some(word) = words.get(index) {
            let value = control_value(word, ansi_c_word)?;
            if value == "--" {
                index += 1;
                if command_string {
                    return self.inspect_shell_script(
                        words,
                        index,
                        depth,
                        ansi_c_word,
                        piped_input || input.uninspectable_input || !input.bodies.is_empty(),
                    );
                }
                break;
            }
            if value.starts_with("--") {
                if matches!(value.as_str(), "--help" | "--version") {
                    return Ok(None);
                }
                if matches!(value.as_str(), "--rcfile" | "--init-file") {
                    if words.get(index + 1).is_none() {
                        return Err(format!("shell option {value} is missing its value"));
                    }
                    index += 2;
                    continue;
                }
                if value.starts_with("--rcfile=") || value.starts_with("--init-file=") {
                    index += 1;
                    continue;
                }
                if matches!(
                    value.as_str(),
                    "--debug"
                        | "--debugger"
                        | "--dump-po-strings"
                        | "--dump-strings"
                        | "--login"
                        | "--noediting"
                        | "--noprofile"
                        | "--norc"
                        | "--posix"
                        | "--pretty-print"
                        | "--restricted"
                        | "--verbose"
                ) {
                    index += 1;
                    continue;
                }
                return Err(format!("unsupported shell option: {value}"));
            }
            if value.starts_with('-') || value.starts_with('+') {
                let operand_count =
                    scan_shell_option_token(&value, &mut command_string, &mut reads_stdin)?;
                index += 1;
                for _ in 0..operand_count {
                    let operand = words
                        .get(index)
                        .ok_or_else(|| format!("shell option {value} is missing its value"))?;
                    control_value(operand, ansi_c_word)?;
                    index += 1;
                }
                continue;
            }
            if command_string {
                return self.inspect_shell_script(
                    words,
                    index,
                    depth,
                    ansi_c_word,
                    piped_input || input.uninspectable_input || !input.bodies.is_empty(),
                );
            }
            break;
        }

        if command_string {
            return Err("shell -c is missing its script".to_string());
        }
        if !reads_stdin && index < words.len() {
            return Ok(None);
        }
        for body in &input.bodies {
            if let Some(blocked) = self.inspect_script(body, depth + 1)? {
                return Ok(Some(blocked));
            }
        }
        if !input.bodies.is_empty() {
            return Ok(None);
        }
        if piped_input || input.uninspectable_input {
            return Err(
                "shell reads command text from an input that cannot be inspected".to_string(),
            );
        }
        Ok(None)
    }

    fn inspect_shell_script(
        &mut self,
        words: &[Word],
        script_index: usize,
        depth: usize,
        ansi_c_word: bool,
        inherited_stdin: bool,
    ) -> Result<Option<String>, String> {
        let script = words
            .get(script_index)
            .ok_or_else(|| "shell -c is missing its script".to_string())?;
        self.inspect_script_with_stdin(
            &control_value(script, ansi_c_word)?,
            depth + 1,
            inherited_stdin,
        )
    }

    fn collect_shell_inputs(&mut self, script: &str) -> Result<Vec<ShellInput>, String> {
        let tree = self
            .parser
            .parse(script, None)
            .ok_or_else(|| "tree-sitter failed to parse shell input".to_string())?;
        let root = tree.root_node();
        if root.has_error() {
            return Err("tree-sitter reported incomplete shell syntax".to_string());
        }
        let mut inputs = Vec::new();
        collect_inputs(root, script.as_bytes(), &mut inputs);
        Ok(inputs)
    }

    fn leading_assignment_count(&mut self, command: &str) -> Option<usize> {
        let tree = self.parser.parse(command, None)?;
        let root = tree.root_node();
        if root.has_error() {
            return None;
        }
        let command_node = first_command_node(root)?;
        let mut cursor = command_node.walk();
        let count = command_node
            .named_children(&mut cursor)
            .filter(|child| child.kind() == "variable_assignment")
            .count();
        Some(count)
    }
}

enum RtkResult {
    Done(Option<String>),
    Inner(Vec<Word>),
}

#[derive(Default)]
struct ShellInput {
    header: String,
    bodies: Vec<String>,
    uninspectable_input: bool,
}

impl ShellInput {
    fn applies_to(&self, command: &str) -> bool {
        self.header == command
            || (self.uninspectable_input
                && self
                    .header
                    .strip_prefix(command)
                    .is_some_and(|tail| tail.trim_start().starts_with('<')))
    }
}

fn semantic_words(segment: &ShellSegment) -> Vec<Word> {
    match shlex::split(&segment.command) {
        Some(values) if values.len() == segment.words.len() => values
            .into_iter()
            .zip(&segment.words)
            .map(|(value, original)| Word::with_kind(value, original.kind()))
            .collect(),
        _ => segment.words.clone(),
    }
}

fn first_command_node(node: Node<'_>) -> Option<Node<'_>> {
    if node.kind() == "command" {
        return Some(node);
    }
    // Commands inside assignments or substitutions are not this segment's command.
    if !matches!(
        node.kind(),
        "program" | "list" | "pipeline" | "redirected_statement" | "negated_command"
    ) {
        return None;
    }
    let mut cursor = node.walk();
    let command = node
        .named_children(&mut cursor)
        .find_map(first_command_node);
    command
}

fn control_value(word: &Word, ansi_c_word: bool) -> Result<String, String> {
    if word.is_expansion() {
        return Err(format!("dynamic shell word cannot be inspected: {word}"));
    }
    let value = word.as_str();
    if ansi_c_word && (value.starts_with('$') || value.contains('\\')) {
        let encoded = value.strip_prefix('$').unwrap_or(value);
        if encoded.contains('\\') {
            return Err(format!(
                "ANSI-C escapes in an execution-sensitive word cannot be inspected: {value}"
            ));
        }
        return Ok(encoded.to_string());
    }
    Ok(value.to_string())
}

fn basename(value: String) -> String {
    value.rsplit('/').next().unwrap_or(&value).to_string()
}

fn strip_wrapper(spec: &WrapperSpec, words: &[Word]) -> Result<Vec<Word>, String> {
    let wrapper = &spec.name;
    let mut index = 1;
    let mut positionals_skipped = 0;

    while let Some(word) = words.get(index) {
        let value = word.as_str();
        if (spec.has_terminator || wrapper == "time") && value == "--" {
            index += 1;
            break;
        }
        if spec.skip_env_assignments && word.is_assignment() {
            index += 1;
            continue;
        }
        if value.starts_with("--") {
            let option = value.split_once('=').map_or(value, |(option, _)| option);
            let takes_value = spec.long_value_flags.iter().any(|flag| flag == option)
                || (wrapper == "time" && matches!(option, "--format" | "--output"));
            if takes_value && !value.contains('=') {
                index += 1;
                if words.get(index).is_none() {
                    return Err(format!(
                        "wrapper {wrapper} option {option} is missing its value"
                    ));
                }
            }
            index += 1;
            continue;
        }
        if value.starts_with('-') && value.len() > 1 {
            let mut options = value[1..].chars().peekable();
            while let Some(option) = options.next() {
                let flag = format!("-{option}");
                let takes_value = spec.short_value_flags.iter().any(|known| known == &flag)
                    || (wrapper == "time" && matches!(option, 'f' | 'o'));
                if takes_value {
                    if options.peek().is_none() {
                        index += 1;
                        if words.get(index).is_none() {
                            return Err(format!(
                                "wrapper {wrapper} option {flag} is missing its value"
                            ));
                        }
                    }
                    break;
                }
            }
            index += 1;
            continue;
        }
        if positionals_skipped < spec.skip_positionals {
            positionals_skipped += 1;
            index += 1;
            continue;
        }
        break;
    }

    Ok(words.get(index..).unwrap_or_default().to_vec())
}

fn scan_shell_option_token(
    value: &str,
    command_string: &mut bool,
    reads_stdin: &mut bool,
) -> Result<usize, String> {
    let body = value
        .strip_prefix('-')
        .or_else(|| value.strip_prefix('+'))
        .ok_or_else(|| format!("unsupported shell option: {value}"))?;
    if body.is_empty() {
        return Err(format!("unsupported shell option: {value}"));
    }
    let mut operand_count = 0;
    for option in body.chars() {
        match option {
            'c' => *command_string = true,
            's' => *reads_stdin = true,
            'o' | 'O' => operand_count += 1,
            'a' | 'b' | 'e' | 'f' | 'h' | 'i' | 'k' | 'l' | 'm' | 'n' | 'p' | 'r' | 't' | 'u'
            | 'v' | 'x' | 'B' | 'C' | 'D' | 'E' | 'H' | 'P' | 'T' => {}
            _ => return Err(format!("unsupported shell option: -{option}")),
        }
    }
    Ok(operand_count)
}

fn word_matches_flag(word: &str, flag: &str) -> bool {
    word == flag
        || word.starts_with(&format!("{flag}="))
        || (flag.starts_with('-')
            && flag.len() == 2
            && word.starts_with('-')
            && !word.starts_with("--")
            && word[1..].contains(flag.chars().nth(1).expect("short flag has one letter")))
}

fn has_xargs_replace_flag(words: &[Word], ansi_c_word: bool) -> Result<bool, String> {
    for word in words {
        let value = control_value(word, ansi_c_word)?;
        if value == "--replace"
            || value.starts_with("--replace=")
            || (value.starts_with('-')
                && !value.starts_with("--")
                && value[1..].chars().any(|flag| matches!(flag, 'I' | 'i')))
        {
            return Ok(true);
        }
    }
    Ok(false)
}

fn is_command_query(words: &[Word], ansi_c_word: bool) -> Result<bool, String> {
    let mut index = 1;
    while let Some(word) = words.get(index) {
        let value = control_value(word, ansi_c_word)?;
        if value == "--" {
            return Ok(false);
        }
        if value == "--verbose" {
            return Ok(true);
        }
        if value.starts_with('-') && !value.starts_with("--") && value.len() > 1 {
            let mut query = false;
            for option in value[1..].chars() {
                match option {
                    'p' => {}
                    'v' | 'V' => query = true,
                    _ => return Ok(false),
                }
            }
            if query {
                return Ok(true);
            }
            index += 1;
            continue;
        }
        return Ok(false);
    }
    Ok(false)
}

fn is_runtime_git_command_safe(words: &[Word], ansi_c_word: bool) -> Result<bool, String> {
    let Some(invocation) = parse_git_invocation(words, ansi_c_word)? else {
        return Ok(false);
    };
    Ok(matches!(
        invocation.subcommand.as_str(),
        "status" | "diff" | "log" | "show" | "rev-parse" | "ls-files" | "describe"
    ))
}

struct GitInvocation {
    subcommand: String,
    args_start: usize,
}

fn is_blocked_command(words: &[Word], ansi_c_word: bool) -> Result<bool, String> {
    let base = basename(control_value(&words[0], ansi_c_word)?);
    if base == "git-push" {
        return Ok(true);
    }
    let Some(invocation) = parse_git_invocation(words, ansi_c_word)? else {
        return Ok(false);
    };
    inspect_git_args(
        &invocation.subcommand,
        &words[invocation.args_start..],
        ansi_c_word,
    )
}

fn parse_git_invocation(
    words: &[Word],
    ansi_c_word: bool,
) -> Result<Option<GitInvocation>, String> {
    let base = basename(control_value(&words[0], ansi_c_word)?);
    match base.as_str() {
        "git-stash" => Ok(Some(GitInvocation {
            subcommand: "stash".to_string(),
            args_start: 1,
        })),
        "git-checkout" => Ok(Some(GitInvocation {
            subcommand: "checkout".to_string(),
            args_start: 1,
        })),
        "git-restore" => Ok(Some(GitInvocation {
            subcommand: "restore".to_string(),
            args_start: 1,
        })),
        "git-reset" => Ok(Some(GitInvocation {
            subcommand: "reset".to_string(),
            args_start: 1,
        })),
        "git-clean" => Ok(Some(GitInvocation {
            subcommand: "clean".to_string(),
            args_start: 1,
        })),
        "git-rm" => Ok(Some(GitInvocation {
            subcommand: "rm".to_string(),
            args_start: 1,
        })),
        "git-switch" => Ok(Some(GitInvocation {
            subcommand: "switch".to_string(),
            args_start: 1,
        })),
        "git-push" => Ok(Some(GitInvocation {
            subcommand: "push".to_string(),
            args_start: 1,
        })),
        "git" => parse_git_command(words, ansi_c_word),
        _ => Ok(None),
    }
}

fn parse_git_command(words: &[Word], ansi_c_word: bool) -> Result<Option<GitInvocation>, String> {
    let mut index = 1;
    // Consume only documented global options; guessing an option's arity can
    // shift a destructive subcommand into an operand.
    loop {
        let Some(word) = words.get(index) else {
            return Ok(None);
        };
        let value = control_value(word, ansi_c_word)?;
        if value == "--" {
            index += 1;
            return git_subcommand_at(words, index, ansi_c_word);
        }
        if value == "-C" {
            require_git_option_operand(words, index, &value, ansi_c_word)?;
            index += 2;
            continue;
        }
        if value.starts_with("-C") && value.len() > 2 {
            index += 1;
            continue;
        }
        if value == "-c" {
            let config = git_option_operand(words, index, &value, ansi_c_word)?;
            inspect_git_config(&config)?;
            index += 2;
            continue;
        }
        if let Some(config) = value.strip_prefix("-c").filter(|config| !config.is_empty()) {
            inspect_git_config(config)?;
            index += 1;
            continue;
        }
        if value == "--config-env" || value.starts_with("--config-env=") {
            return Err("git --config-env cannot be inspected".to_string());
        }
        if matches!(
            value.as_str(),
            "--git-dir" | "--work-tree" | "--namespace" | "--exec-path" | "--super-prefix"
        ) {
            require_git_option_operand(words, index, &value, ansi_c_word)?;
            index += 2;
            continue;
        }
        if matches!(
            value.as_str(),
            "--literal-pathspecs"
                | "--glob-pathspecs"
                | "--noglob-pathspecs"
                | "--icase-pathspecs"
                | "--no-replace-objects"
                | "--no-lazy-fetch"
                | "--no-optional-locks"
                | "--no-advice"
                | "--paginate"
                | "--no-pager"
                | "--bare"
                | "-p"
                | "-P"
        ) {
            index += 1;
            continue;
        }
        if value.starts_with("--git-dir=")
            || value.starts_with("--work-tree=")
            || value.starts_with("--namespace=")
            || value.starts_with("--exec-path=")
            || value.starts_with("--super-prefix=")
        {
            index += 1;
            continue;
        }
        if matches!(value.as_str(), "-h" | "--help" | "-v" | "--version") {
            return Ok(None);
        }
        if value.starts_with('-') {
            return Err(format!("unsupported git global option: {value}"));
        }
        return git_subcommand_at(words, index, ansi_c_word);
    }
}

fn git_subcommand_at(
    words: &[Word],
    index: usize,
    ansi_c_word: bool,
) -> Result<Option<GitInvocation>, String> {
    let Some(word) = words.get(index) else {
        return Ok(None);
    };
    let subcommand = control_value(word, ansi_c_word)?;
    if subcommand.starts_with('-') {
        return Err(format!("unsupported git subcommand: {subcommand}"));
    }
    Ok(Some(GitInvocation {
        subcommand,
        args_start: index + 1,
    }))
}

fn git_option_operand(
    words: &[Word],
    index: usize,
    option: &str,
    ansi_c_word: bool,
) -> Result<String, String> {
    words
        .get(index + 1)
        .ok_or_else(|| format!("git global option {option} is missing its value"))
        .and_then(|word| control_value(word, ansi_c_word))
}

fn require_git_option_operand(
    words: &[Word],
    index: usize,
    option: &str,
    ansi_c_word: bool,
) -> Result<(), String> {
    git_option_operand(words, index, option, ansi_c_word).map(|_| ())
}

fn inspect_git_config(config: &str) -> Result<(), String> {
    let (name, _) = config
        .split_once('=')
        .ok_or_else(|| format!("git config option is missing '=': {config}"))?;
    if name
        .get(..6)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("alias."))
    {
        return Err("git aliases cannot be inspected".to_string());
    }
    Ok(())
}

fn inspect_git_args(subcommand: &str, words: &[Word], ansi_c_word: bool) -> Result<bool, String> {
    if !matches!(
        subcommand,
        "push" | "stash" | "restore" | "checkout" | "reset" | "clean" | "rm" | "switch"
    ) {
        return Ok(false);
    }
    let first = words
        .first()
        .map(|word| control_value(word, ansi_c_word))
        .transpose()?;
    if matches!(first.as_deref(), Some("-h" | "--help")) {
        return Ok(false);
    }
    if subcommand == "stash" {
        return inspect_stash_args(first.as_deref());
    }
    let args = words
        .iter()
        .map(|word| control_value(word, ansi_c_word))
        .collect::<Result<Vec<_>, _>>()?;
    match subcommand {
        "push" => Ok(true),
        "restore" => Ok(true),
        "checkout" => inspect_checkout_args(&args),
        "reset" => inspect_reset_args(&args),
        "clean" => inspect_clean_args(&args),
        "rm" => inspect_rm_args(&args),
        "switch" => inspect_switch_args(&args),
        _ => Ok(false),
    }
}

fn inspect_stash_args(first: Option<&str>) -> Result<bool, String> {
    let Some(first) = first else {
        return Ok(true);
    };
    if matches!(first, "-h" | "--help") {
        return Ok(false);
    }
    if matches!(first, "list" | "show" | "create") {
        return Ok(false);
    }
    Ok(true)
}

fn inspect_checkout_args(args: &[String]) -> Result<bool, String> {
    let mut positional_count = 0;
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        if matches!(
            arg.as_str(),
            "--" | "-f" | "--force" | "--ours" | "--theirs" | "-p" | "--patch" | "-B" | "--merge"
        ) || arg.starts_with("--force=")
            || (arg.starts_with('-')
                && !arg.starts_with("--")
                && !arg.starts_with("-b")
                && arg[1..].chars().any(|flag| matches!(flag, 'f' | 'B' | 'p')))
        {
            return Ok(true);
        }
        if arg == "-b" {
            index += 1;
            if args.get(index).is_none() {
                return Err("git checkout -b is missing its branch name".to_string());
            }
        } else if arg.starts_with("-b") && arg.len() > 2 {
            // The remainder of this token is the branch name, not more flags.
        } else if arg.starts_with("--track=") {
            // --track's optional mode is attached with '='.
        } else if arg.starts_with("--") {
            if !matches!(
                arg.as_str(),
                "--track"
                    | "--no-track"
                    | "--detach"
                    | "--guess"
                    | "--no-guess"
                    | "--quiet"
                    | "--progress"
                    | "--no-progress"
            ) {
                return Err(format!("unsupported git checkout option: {arg}"));
            }
        } else if arg.starts_with('-') {
            for flag in arg
                .strip_prefix('-')
                .expect("checkout option starts with '-'")
                .chars()
            {
                if !matches!(flag, 'd' | 'l' | 'q' | 't') {
                    return Err(format!("unsupported git checkout option: -{flag}"));
                }
            }
        } else {
            positional_count += 1;
        }
        index += 1;
    }
    Ok(positional_count >= 2)
}

fn inspect_reset_args(args: &[String]) -> Result<bool, String> {
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        if arg == "--" {
            break;
        }
        if matches!(arg.as_str(), "--hard" | "--keep" | "--merge")
            || arg.starts_with("--hard=")
            || arg.starts_with("--keep=")
            || arg.starts_with("--merge=")
        {
            return Ok(true);
        }
        if arg == "--pathspec-from-file" {
            index += 1;
            if args.get(index).is_none() {
                return Err("git reset --pathspec-from-file is missing its file".to_string());
            }
        } else if arg.starts_with("--")
            && !matches!(
                arg.as_str(),
                "--mixed"
                    | "--soft"
                    | "--quiet"
                    | "--patch"
                    | "--intent-to-add"
                    | "--pathspec-file-nul"
            )
            && !arg.starts_with("--pathspec-from-file=")
        {
            return Err(format!("unsupported git reset option: {arg}"));
        }
        if arg.starts_with('-') && !arg.starts_with("--") {
            for flag in arg[1..].chars() {
                if !matches!(flag, 'N' | 'p' | 'q') {
                    return Err(format!("unsupported git reset option: -{flag}"));
                }
            }
        }
        index += 1;
    }
    Ok(false)
}

fn inspect_clean_args(args: &[String]) -> Result<bool, String> {
    let mut dry_run = false;
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        if arg == "--" {
            break;
        }
        let mut consume_next = false;
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--no-dry-run" => dry_run = false,
            "--force" | "--no-force" | "--interactive" | "--quiet" => {}
            "--exclude" => consume_next = true,
            value if value.starts_with("--exclude=") => {}
            value if !value.starts_with('-') => {}
            value if value.starts_with('-') && !value.starts_with("--") => {
                let mut flags = value[1..].chars().peekable();
                while let Some(flag) = flags.next() {
                    match flag {
                        'n' => dry_run = true,
                        'd' | 'f' | 'i' | 'q' | 'x' | 'X' => {}
                        'e' => {
                            consume_next = flags.peek().is_none();
                            break;
                        }
                        _ => return Err(format!("unsupported git clean option: -{flag}")),
                    }
                }
            }
            _ => return Err(format!("unsupported git clean option: {arg}")),
        }
        if consume_next {
            index += 1;
            if args.get(index).is_none() {
                return Err(format!("git clean option {arg} is missing its pattern"));
            }
        }
        index += 1;
    }
    Ok(!dry_run)
}

fn inspect_switch_args(args: &[String]) -> Result<bool, String> {
    for arg in args {
        if matches!(
            arg.as_str(),
            "-f" | "--force" | "-C" | "--force-create" | "--discard-changes"
        ) || arg.starts_with("--force=")
            || (arg.starts_with('-')
                && !arg.starts_with("--")
                && !arg.starts_with("-c")
                && arg[1..].chars().any(|flag| flag == 'f'))
        {
            return Ok(true);
        }
        if arg.starts_with("--")
            && !matches!(
                arg.as_str(),
                "--create"
                    | "--detach"
                    | "--guess"
                    | "--no-guess"
                    | "--quiet"
                    | "--progress"
                    | "--no-progress"
                    | "--track"
                    | "--no-track"
            )
            && !arg.starts_with("--create=")
            && !arg.starts_with("--track=")
        {
            return Err(format!("unsupported git switch option: {arg}"));
        }
        if arg.starts_with("-c") && arg.len() > 2 {
            continue;
        }
        if arg.starts_with('-') && !arg.starts_with("--") {
            for flag in arg[1..].chars() {
                if !matches!(flag, 'c' | 'd' | 'q') {
                    return Err(format!("unsupported git switch option: -{flag}"));
                }
            }
        }
    }
    Ok(false)
}

fn inspect_rm_args(args: &[String]) -> Result<bool, String> {
    let mut cached = false;
    let mut dry_run = false;
    let mut index = 0;
    while let Some(arg) = args.get(index) {
        if arg == "--" {
            break;
        }
        match arg.as_str() {
            "--cached" => cached = true,
            "--no-cached" => cached = false,
            "--dry-run" => dry_run = true,
            "--no-dry-run" => dry_run = false,
            "--force" | "--quiet" | "--ignore-unmatch" | "--sparse" | "--pathspec-file-nul" => {}
            "--pathspec-from-file" => {
                index += 1;
                if args.get(index).is_none() {
                    return Err("git rm --pathspec-from-file is missing its file".to_string());
                }
            }
            value if value.starts_with("--pathspec-from-file=") => {}
            value if !value.starts_with('-') => {}
            value if value.starts_with('-') && !value.starts_with("--") => {
                for flag in value[1..].chars() {
                    match flag {
                        'n' => dry_run = true,
                        'f' | 'q' | 'r' => {}
                        _ => return Err(format!("unsupported git rm option: -{flag}")),
                    }
                }
            }
            _ => return Err(format!("unsupported git rm option: {arg}")),
        }
        index += 1;
    }
    Ok(!(cached || dry_run))
}

fn collect_inputs(node: Node<'_>, source: &[u8], inputs: &mut Vec<ShellInput>) {
    let owns_input = node.kind() == "redirected_statement"
        || (node.kind() == "command" && has_direct_uninspectable_input(node, source));
    if owns_input {
        let mut bodies = Vec::new();
        collect_bodies(node, source, &mut bodies);
        let uninspectable_input = contains_uninspectable_input(node, source);
        if !bodies.is_empty() || uninspectable_input {
            let header_end = first_body_start(node).unwrap_or(node.end_byte());
            if let Ok(header) = std::str::from_utf8(&source[node.start_byte()..header_end]) {
                inputs.push(ShellInput {
                    header: header.trim().to_string(),
                    bodies,
                    uninspectable_input,
                });
            }
        }
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_inputs(child, source, inputs);
    }
}

fn has_direct_uninspectable_input(node: Node<'_>, source: &[u8]) -> bool {
    let mut cursor = node.walk();
    let found = node
        .named_children(&mut cursor)
        .any(|child| contains_uninspectable_input(child, source));
    found
}

fn collect_bodies(node: Node<'_>, source: &[u8], bodies: &mut Vec<String>) {
    if node.kind() == "heredoc_body" {
        if let Ok(body) = node.utf8_text(source) {
            bodies.push(body.to_string());
        }
        return;
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_bodies(child, source, bodies);
    }
}

fn first_body_start(node: Node<'_>) -> Option<usize> {
    if node.kind() == "heredoc_body" {
        return Some(node.start_byte());
    }
    let mut cursor = node.walk();
    node.named_children(&mut cursor)
        .filter_map(first_body_start)
        .min()
}

fn contains_uninspectable_input(node: Node<'_>, source: &[u8]) -> bool {
    if node.kind() == "herestring_redirect" {
        return true;
    }
    if node.kind() == "file_redirect" {
        return node.utf8_text(source).is_ok_and(|text| {
            let text = text.trim_start_matches(|character: char| character.is_ascii_digit());
            text.starts_with('<') && !text.starts_with("<<")
        });
    }
    let mut cursor = node.walk();
    let found = node
        .named_children(&mut cursor)
        .any(|child| contains_uninspectable_input(child, source));
    found
}

#[cfg(test)]
mod tests {
    use super::{inspect_command, inspect_hook_input, Decision, Inspector};

    fn assert_blocked(command: &str) {
        let decision = inspect_command(command);
        assert!(
            matches!(decision, Decision::Block { .. }),
            "expected block: {command}; got {decision:?}"
        );
    }

    fn assert_allowed(command: &str) {
        assert_eq!(
            inspect_command(command),
            Decision::Allow,
            "expected allow: {command}"
        );
    }

    fn assert_fail_closed(command: &str) {
        let decision = inspect_command(command);
        assert!(
            matches!(&decision, Decision::FailClosed(_)),
            "expected fail closed: {command}; got {:?}",
            decision
        );
    }

    #[test]
    fn blocks_git_families_and_keeps_safe_forms() {
        for command in [
            "git stash",
            "git stash pop",
            "git checkout -- target",
            "git restore -- target",
            "git reset --hard HEAD",
            "git reset --keep HEAD",
            "git reset --merge HEAD",
            "git clean -fd",
            "git clean",
            "git clean --force",
            "git rm target",
            "git switch -C branch",
            "git switch --force-create branch",
            "git -C /tmp restore -- target",
            "git -c core.quotePath=false reset --hard HEAD",
            "git checkout HEAD -- target",
            "git-restore -- target",
            "git-reset --hard HEAD",
            "git-clean -fd",
            "git-rm target",
            "git-switch -C branch",
        ] {
            assert_blocked(command);
        }
        for command in [
            "git status",
            "git stash list",
            "git stash show",
            "git stash create",
            "git checkout branch",
            "git checkout --help",
            "git checkout --quiet branch",
            "git checkout -b feature main",
            "git checkout -bfeature main",
            "git restore --help",
            "git reset",
            "git reset --help",
            "git reset --mixed HEAD",
            "git reset --soft HEAD",
            "git clean -n",
            "git clean -nfdx",
            "git clean -n -e pattern",
            "git clean --dry-run --exclude pattern",
            "git clean --dry-run -fdx",
            "git clean --dry-run",
            "git clean --help",
            "git rm --cached target",
            "git rm --cached -r target",
            "git rm --cached --pathspec-from-file paths",
            "git rm --dry-run target",
            "git rm --dry-run -r target",
            "git switch branch",
            "git switch --help",
            "git switch --quiet branch",
            "git switch -c branch",
            "git switch -cfeature main",
            "git switch --track origin/main",
            "git push --help",
            r"git status $'safe\nargument'",
            r"git stash create $'safe\nmessage'",
        ] {
            assert_allowed(command);
        }
    }

    #[test]
    fn handles_shell_option_operands_before_script_text() {
        for command in [
            r#"bash -c -- "git restore -- target""#,
            r#"bash -Oc extglob "git restore -- target""#,
            "bash -cO extglob 'git restore -- target'",
            "bash -co pipefail 'git restore -- target'",
            "bash -c -O extglob 'git restore -- target'",
            "bash -c -o pipefail 'git restore -- target'",
        ] {
            assert_blocked(command);
        }
    }

    #[test]
    fn inspects_static_traps_and_rejects_dynamic_actions() {
        for command in [
            r#"trap "git restore -- target" EXIT"#,
            "trap 'git restore -- target' EXIT",
        ] {
            assert_blocked(command);
        }
        for command in ["trap", "trap -p", "trap -p EXIT", "trap - EXIT"] {
            assert_allowed(command);
        }
        assert_fail_closed(r#"trap "$ACTION" EXIT"#);
        assert_fail_closed(r#"trap -- "$ACTION" EXIT"#);
    }

    #[test]
    fn parses_git_global_options_with_explicit_arity() {
        for command in [
            "git --git-dir .git restore -- target",
            "git --git-dir=.git restore -- target",
            "git --work-tree . restore -- target",
            "git --work-tree=. restore -- target",
            "git -C /tmp restore -- target",
            "git -C/tmp restore -- target",
            "git -c core.quotePath=false restore -- target",
            "git --git-dir .git -- restore -- target",
        ] {
            assert_blocked(command);
        }
        assert_allowed("git -c core.quotePath=false status");
        assert_fail_closed("git -e /tmp restore -- target");
        assert_fail_closed("git -e/tmp restore -- target");
        assert_fail_closed("git --unknown-global-option restore -- target");
        assert_fail_closed("git -- --git-dir .git restore -- target");
        assert_fail_closed(r#"git -c alias.wipe="restore --" wipe target"#);
        assert_fail_closed(
            "ALIAS_VALUE='restore --' git --config-env=alias.wipe=ALIAS_VALUE wipe target",
        );
    }

    #[test]
    fn blocks_destructive_family_variants() {
        for command in [
            "git stash -u",
            "git -c clean.requireForce=false clean",
            "git checkout -f branch",
            "git checkout --force branch",
            "git checkout --ours target",
            "git checkout HEAD target",
            "git switch --discard-changes branch",
            "git -c clean.requireForce=0 clean",
        ] {
            assert_blocked(command);
        }
        for command in ["git stash list", "git stash show", "git stash create"] {
            assert_allowed(command);
        }
    }

    #[test]
    fn allows_direct_rm_commands() {
        for command in [
            "rm -rf target",
            "/bin/rm -rf target",
            "env rm -rf target",
            "bash -c 'rm -rf target'",
        ] {
            assert_allowed(command);
        }
        assert_blocked("git rm target");
    }

    #[test]
    fn honors_git_option_boundaries_and_safe_reset_modes() {
        for command in [
            "git clean -f -- -n",
            "git clean -f -- --dry-run",
            "git rm -- --cached",
            "git rm -- -n",
            "git rm --pathspec-from-file --cached",
        ] {
            assert_blocked(command);
        }
        for command in [
            "git clean -n -- --no-dry-run",
            "git rm -n -- --no-dry-run",
            "git rm --cached --pathspec-from-file --no-cached",
            "git reset -- target",
            "git reset -p",
            "git reset --patch",
            "git reset -N target",
        ] {
            assert_allowed(command);
        }
    }

    #[test]
    fn parses_common_wrapper_option_clusters_and_gnu_time() {
        for command in [
            "env -iu FOO git restore -- target",
            "xargs -rn 1 git restore -- target <<< value",
            "/usr/bin/time -f marker git restore -- target",
            "/usr/bin/time --format marker git restore -- target",
        ] {
            assert_blocked(command);
        }
        for command in [
            "env -iu FOO git status",
            "xargs -rn 1 git status <<< value",
            "/usr/bin/time -f marker git status",
            "/usr/bin/time --output report git status",
        ] {
            assert_allowed(command);
        }
    }

    #[test]
    fn preserves_stdin_provenance_across_shell_command_strings() {
        assert_fail_closed("printf '%s\\n' 'git restore -- target' | bash -c 'bash'");
        assert_allowed("printf '%s\\n' data | bash -c 'cat'");
    }

    #[test]
    fn does_not_trust_runtime_xargs_arguments() {
        assert_fail_closed("xargs git");
        assert_fail_closed("xargs -a args.txt git");
        assert_fail_closed("printf '%s\\n' restore | xargs git");
        assert_fail_closed("xargs git <<< restore");
        assert_fail_closed("printf '%s\\n' git | xargs env git");
        assert_fail_closed("printf '%s\\n' restore | xargs rtk git");
        assert_fail_closed("printf '%s\\n' restore | xargs rtk proxy git");
        assert_fail_closed("printf '%s\\n' restore | xargs env rtk git");
        assert_fail_closed("printf '%s\\n' restore | xargs env");
        assert_fail_closed("printf '%s\\n' restore | xargs rtk run");
        assert_fail_closed("printf '%s\\n' '-D main' | xargs git branch");
        assert_allowed("printf '%s\\n' restore | xargs git status");
        assert_allowed("xargs git status <<< restore");
        assert_allowed("xargs env git status");
        assert_allowed("xargs rtk git status");
    }

    #[test]
    fn allows_git_query_commands() {
        assert_allowed("command -v git restore");
        assert_allowed("command -V git restore");
        assert_allowed("command -pv git restore");
        assert_allowed("command -pV git restore");
    }

    #[test]
    fn blocks_static_shell_wrappers() {
        for command in [
            "bash -c 'git restore -- target; true'",
            "sh -c 'git restore -- target; true'",
            "bash -lc 'git restore -- target; true'",
            "bash -o pipefail -c 'git restore -- target'",
            "bash -O extglob -c 'git restore -- target'",
            "bash --rcfile /dev/null -c 'git restore -- target'",
            "bash +x -c 'git restore -- target'",
            "bash +xc 'git restore -- target'",
            "bash -xO extglob -c 'git restore -- target'",
            "bash +xo posix -c 'git restore -- target'",
            "bash - <<'EOF'\ngit restore -- target\nEOF",
            "bash -- - <<'EOF'\ngit restore -- target\nEOF",
            "bash +O extglob -c 'git restore -- target'",
            "bash +o posix -c 'git restore -- target'",
            "env -- bash -c 'git restore -- target'",
            "env -i bash -c 'git restore -- target'",
            "/usr/bin/env bash -c 'git restore -- target'",
            "command -- bash -c 'git restore -- target'",
            "bash -c '(git restore -- target)'",
            "bash -c '{ git restore -- target; }'",
            "bash -c 'if true; then git restore -- target; fi'",
            "bash -c '! git restore -- target'",
            "rtk proxy bash -c 'git restore -- target'",
            "rtk err bash -c 'git restore -- target'",
            "rtk -v proxy bash -c 'git restore -- target'",
            "rtk bash -c 'git restore -- target'",
            "rtk run 'git restore -- target; true'",
            "rtk summary bash -c 'git restore -- target; true'",
            "rtk test bash -c 'git restore -- target; true'",
            "watch 'git restore -- target'",
            "eval 'git restore -- target'",
            ">/dev/null bash -c 'git restore -- target'",
            "echo ok # comment\ngit restore -- target",
            "bash -c 'sh -c \"git restore -- target\"'",
        ] {
            assert_blocked(command);
        }
    }

    #[test]
    fn allows_static_wrapper_commands_and_rejects_only_dynamic_xargs() {
        for command in [
            "xargs git status",
            "watch git status",
            "env git status -S",
            "bash +x -c 'git status'",
            "bash -p -c 'git status'",
            "bash --noprofile --norc -c 'git status'",
            "git -p status",
            "git -P status",
            "cat <<< 'git restore -- target'",
            "rtk --version",
            "rtk --help",
            "rtk -v --version",
            "rtk run --help",
            "rtk proxy -h",
            "rtk err --help",
            "rtk summary --help",
            "rtk test --help",
            "rtk summary git status",
            "rtk test git status",
        ] {
            assert_allowed(command);
        }
        for command in [
            "xargs -I{} git status",
            "xargs -i{} git status",
            "xargs --replace={} git status",
            "xargs -n1I{} git status",
            "parallel git status",
        ] {
            assert!(matches!(inspect_command(command), Decision::FailClosed(_)));
        }
        assert_blocked("xargs git restore -- target");
    }

    #[test]
    fn decodes_static_shell_quoting() {
        assert_blocked(r"g\it restore -- target");
        assert!(matches!(
            inspect_command(r"bash -c $'\x67it restore -- target'"),
            Decision::FailClosed(_)
        ));
        assert_allowed(r"printf '%s\n' $'don\'t'");
    }

    #[test]
    fn distinguishes_shell_input_from_heredoc_data() {
        assert_blocked("bash <<'EOF'\ngit restore -- target\nEOF");
        assert_allowed("bash <<'EOF'\ngit status\nEOF");
        assert_allowed("cat <<'EOF'\ngit restore -- target\nEOF");
        assert_allowed("bash -c 'cat >/dev/null' <<'EOF'\ngit restore -- target\nEOF");
        assert_allowed("bash script/example.sh <<'EOF'\ngit restore -- target\nEOF");
    }

    #[test]
    fn associates_opaque_input_with_its_shell_command() {
        let mut inspector = Inspector::new().expect("parser setup");
        let inputs = inspector
            .collect_shell_inputs("bash <<< 'git restore -- target'")
            .expect("input parse");
        assert_eq!(inputs.len(), 1);
        assert!(inputs[0].uninspectable_input);
        assert!(
            inputs[0].applies_to("bash"),
            "input header was {:?}",
            inputs[0].header
        );
    }

    #[test]
    fn handles_compound_commands_and_literals() {
        assert_blocked("echo ok && git restore -- target");
        assert_blocked("f(){ git restore -- target; }; f");
        assert_allowed("printf '%s\n' '${value:-&git restore}'");
        assert_allowed("'FOO=bar' git restore -- target");
        assert_allowed(">/dev/null 'FOO=bar' git restore -- target");
        assert_allowed("FOO=$(pwd)");
    }

    #[test]
    fn malformed_or_dynamic_execution_fails_closed() {
        for command in [
            "bash -c 'git restore -- target",
            "bash -c --",
            "bash -c \"$SCRIPT\"",
            "bash <<< 'git restore -- target'",
            "eval \"$SCRIPT\"",
            "env -S 'git restore -- target'",
            "bash -c 'coproc git restore -- target; wait'",
            "bash -c 'coproc git restore -- target && true'",
            "bash -c 'coproc git restore -- target || true'",
            "bash -c 'coproc git restore -- target | cat'",
        ] {
            assert!(
                matches!(inspect_command(command), Decision::FailClosed(_)),
                "expected fail closed: {command}"
            );
        }
    }

    #[test]
    fn oversized_shell_input_fails_before_parsing() {
        let command = format!("echo {}", "x".repeat(64 * 1024));
        assert_eq!(
            inspect_command(&command),
            Decision::FailClosed("shell input exceeds 64 KiB".to_string())
        );
    }

    #[test]
    fn combined_env_split_string_fails_closed() {
        assert!(matches!(
            inspect_command("env -iS 'git restore -- target'"),
            Decision::FailClosed(_)
        ));
    }

    #[test]
    fn source_commands_fail_closed() {
        for command in ["source script/example.sh", ". script/example.sh"] {
            assert!(matches!(inspect_command(command), Decision::FailClosed(_)));
        }
    }

    #[test]
    fn input_driven_wrappers_fail_closed() {
        for command in [
            "xargs -I{} bash -c '{}'",
            "parallel bash -c '{}' ::: 'git restore -- target'",
        ] {
            assert!(matches!(inspect_command(command), Decision::FailClosed(_)));
        }
    }

    #[test]
    fn accepts_both_hook_input_key_spellings() {
        assert_eq!(
            inspect_hook_input(r#"{"toolInput":{"command":"git status"}}"#),
            Decision::Allow
        );
    }

    #[test]
    fn inspects_every_duplicate_hook_command() {
        assert_eq!(
            inspect_hook_input(
                r#"{"tool_input":{"command":"git status"},"tool_input":{"command":"git status"}}"#,
            ),
            Decision::Allow
        );
        for input in [
            r#"{"tool_input":{"command":"git status"},"tool_input":{"command":"git restore -- target"}}"#,
            r#"{"tool_input":{"command":"git restore -- target"},"toolInput":{"command":"git status"}}"#,
        ] {
            assert!(
                matches!(inspect_hook_input(input), Decision::Block { .. }),
                "expected duplicate command to block: {input}"
            );
        }
        assert!(matches!(
            inspect_hook_input(
                r#"{"tool_input":{"command":"git status","command":"git restore -- target"}}"#,
            ),
            Decision::FailClosed(_)
        ));
    }
}
