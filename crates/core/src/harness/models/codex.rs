//! Codex's documented app-server model/list RPC. No model turn or account probe.
//! https://developers.openai.com/codex/app-server#models
use super::evidence::{AvailableModel, ModelListEvidence, RuntimeContext};
use crate::process::{Hardened, INTERACTIVE_TIMEOUT};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;

const SOURCE: &str = "codex:model/list";
/// Collect on the actual launch host under its admitted account environment.
/// The caller supplies the active provider because model/list has no provider field.
pub fn collect(context: &RuntimeContext, cwd: &Path) -> ModelListEvidence {
    let failed = |cause: String| ModelListEvidence::Failed {
        source: SOURCE.into(),
        cause,
    };
    let provider = match context
        .current_provider
        .as_ref()
        .or_else(|| (context.providers.len() == 1).then(|| &context.providers[0]))
    {
        Some(provider) if context.providers.contains(provider) => provider.clone(),
        _ => {
            return failed(
                "native model list requires the admitted active provider identity".into(),
            );
        }
    };
    let output = Hardened::codex_app_server(cwd)
        .timeout(INTERACTIVE_TIMEOUT)
        .max_output(crate::registry::MAX_RESPONSE_BYTES)
        .exchange(move |stdout, stdin| {
            let models = exchange(BufReader::new(stdout), stdin, &provider)?;
            serde_json::to_vec(&models).map_err(io::Error::other)
        });
    let output = match output {
        Ok(output) => output,
        Err(error) => return failed(error.to_string()),
    };
    if !output.status.success() {
        return failed(format!("app-server exited {}", output.status));
    }
    let models: Vec<AvailableModel> = match serde_json::from_slice(&output.stdout) {
        Ok(models) => models,
        Err(error) => return failed(format!("invalid normalized model list: {error}")),
    };
    ModelListEvidence::Complete {
        source: SOURCE.into(),
        account: context.account.clone(),
        host: context.host.clone(),
        models,
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeModel {
    model: String,
    is_default: bool,
    #[serde(default)]
    hidden: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    data: Vec<NativeModel>,
    next_cursor: Option<String>,
}
fn send(writer: &mut impl Write, value: Value) -> io::Result<()> {
    serde_json::to_writer(&mut *writer, &value)?;
    writer.write_all(b"\n")?;
    writer.flush()
}
fn response(reader: &mut impl BufRead, id: u64, remaining: &mut usize) -> io::Result<Value> {
    loop {
        let mut line = String::new();
        // Use the registry's existing external JSON budget across the complete discovery.
        let read = reader.take(*remaining as u64 + 1).read_line(&mut line)?;
        if read == 0 {
            return Err(io::Error::other(
                "app-server exited before completing discovery",
            ));
        }
        *remaining = remaining
            .checked_sub(read)
            .ok_or_else(|| io::Error::other("model discovery exceeds the external JSON budget"))?;
        let value: Value = serde_json::from_str(&line)?;
        if value.get("id") == Some(&json!(id)) {
            if let Some(error) = value.get("error") {
                return Err(io::Error::other(format!("model RPC error: {error}")));
            }
            return value
                .get("result")
                .cloned()
                .ok_or_else(|| io::Error::other("model RPC response has no result"));
        }
        if value.get("id").is_some() {
            return Err(io::Error::other("unexpected model RPC request or response"));
        }
        if value.get("method").and_then(Value::as_str).is_none() {
            return Err(io::Error::other("malformed model RPC notification"));
        }
    }
}
fn exchange(
    mut reader: impl BufRead,
    mut writer: impl Write,
    provider: &str,
) -> io::Result<Vec<AvailableModel>> {
    let mut remaining = crate::registry::MAX_RESPONSE_BYTES;
    send(
        &mut writer,
        json!({"id":0,"method":"initialize","params":{"clientInfo":{"name":"kendex","title":"kendex model discovery","version":env!("CARGO_PKG_VERSION")}}}),
    )?;
    response(&mut reader, 0, &mut remaining)?;
    send(&mut writer, json!({"method":"initialized","params":{}}))?;
    let mut cursor: Option<String> = None;
    let mut seen = BTreeSet::new();
    let mut models = Vec::new();
    let mut id = 1_u64;
    loop {
        send(
            &mut writer,
            json!({"id":id,"method":"model/list","params":{"cursor":cursor,"includeHidden":false}}),
        )?;
        let value = response(&mut reader, id, &mut remaining)?;
        // nextCursor must be present. Missing pagination evidence is not complete.
        if value.get("nextCursor").is_none() {
            return Err(io::Error::other(
                "model list response has no pagination evidence",
            ));
        }
        let page: Page = serde_json::from_value(value)?;
        for model in page.data {
            super::ModelRequest::parse(&format!("{provider}/{}", model.model))
                .map_err(io::Error::other)?;
            models.push(AvailableModel {
                provider: provider.into(),
                id: model.model,
                native_selector: None,
                allowed: !model.hidden,
                chat: true,
                is_default: model.is_default,
            });
        }
        match page.next_cursor {
            None => break,
            Some(next) => {
                if next.is_empty() || !seen.insert(next.clone()) {
                    return Err(io::Error::other(
                        "model list repeated or empty pagination cursor",
                    ));
                }
                cursor = Some(next);
            }
        }
        id = id
            .checked_add(1)
            .ok_or_else(|| io::Error::other("model RPC id overflow"))?;
    }
    // Drop the writer here: EOF shuts down the short-lived native server.
    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn initialization_pagination_and_hidden_policy() {
        let peer = concat!(
            "{\"id\":0,\"result\":{}}\n",
            "{\"id\":1,\"result\":{\"data\":[{\"model\":\"gpt-6-sol\",\"isDefault\":true}],\"nextCursor\":\"page-2\"}}\n",
            "{\"id\":2,\"result\":{\"data\":[{\"model\":\"gpt-7-sol\",\"isDefault\":false,\"hidden\":true}],\"nextCursor\":null}}\n"
        );
        let mut written = Vec::new();
        let models = exchange(io::Cursor::new(peer), &mut written, "openai").unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "gpt-6-sol");
        assert!(models[0].is_default);
        assert!(!models[1].allowed);
        let requests: Vec<Value> = String::from_utf8(written)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            requests
                .iter()
                .map(|r| r["method"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["initialize", "initialized", "model/list", "model/list"]
        );
        assert_eq!(requests[3]["params"]["cursor"], "page-2");
    }
    #[test]
    fn failures_never_report_partial_discovery() {
        let initialize = ["initialize"].as_slice();
        let first_page = ["initialize", "initialized", "model/list"].as_slice();
        let second_page = ["initialize", "initialized", "model/list", "model/list"].as_slice();
        for (peer, expected_methods) in [
            ("", initialize),
            ("invalid\n", initialize),
            ("{\"id\":0,\"error\":{\"code\":-1}}\n", initialize),
            (
                "{\"id\":0,\"result\":{}}\n{\"id\":1,\"result\":{\"data\":[]}}\n",
                first_page,
            ),
            (
                "{\"id\":0,\"result\":{}}\n{\"id\":1,\"result\":{\"data\":[],\"nextCursor\":\"next\"}}\n",
                second_page,
            ),
            (
                "{\"id\":0,\"result\":{}}\n{\"id\":1,\"result\":{\"data\":[],\"nextCursor\":\"next\"}}\n{\"id\":2,\"result\":{\"data\":[],\"nextCursor\":\"next\"}}\n",
                second_page,
            ),
        ] {
            let mut written = Vec::new();
            assert!(
                exchange(io::Cursor::new(peer), &mut written, "openai").is_err(),
                "{peer}"
            );
            // An accepted error must not pass by failing at a later EOF.
            let requests: Vec<Value> = String::from_utf8(written)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            assert_eq!(
                requests
                    .iter()
                    .map(|r| r["method"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                expected_methods,
                "{peer}"
            );
        }
    }
}
