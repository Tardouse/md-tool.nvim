mod markdown;
mod server;
mod websocket;

use anyhow::Result;
use clap::Parser;
use server::ServerConfig;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "md-tool-preview",
    about = "Local Markdown preview server for md-tool.nvim"
)]
struct Cli {
    #[arg(long, default_value = "127.0.0.1")]
    host: String,

    #[arg(long, default_value_t = 4399)]
    port: u16,

    #[arg(long, default_value = "info")]
    log_level: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().or_else(|_| {
            EnvFilter::try_new(format!(
                "md_tool_preview={},axum::rejection=warn",
                cli.log_level
            ))
        })?)
        .with_target(false)
        .compact()
        .init();

    server::run(ServerConfig {
        host: cli.host,
        port: cli.port,
    })
    .await
}
