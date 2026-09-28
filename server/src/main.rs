use clap::{Parser, Subcommand};
use std::{io::Read, net::SocketAddr, path::PathBuf, time::Duration};
use yun_server::{AppState, Config};

#[derive(Parser)]
#[command(version, about = "Yun personal music server")]
struct Cli {
    #[arg(
        long,
        global = true,
        env = "YUN_DATA_DIR",
        default_value = "./yun-data"
    )]
    data_dir: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Serve {
        #[arg(long, env = "YUN_BIND", default_value = "127.0.0.1:8080")]
        bind: SocketAddr,
        /// Required on non-loopback listeners. Expose only through a trusted HTTPS reverse proxy.
        #[arg(long)]
        behind_tls_proxy: bool,
        /// Explicit acknowledgement that HTTP loopback is development-only.
        #[arg(long)]
        insecure_loopback: bool,
        #[arg(long, default_value_t=1024*1024*1024)]
        max_file_bytes: i64,
        #[arg(long, default_value_t=20*1024*1024*1024)]
        quota_bytes: i64,
    },
    CreateUser {
        username: String,
        #[arg(long)]
        password_stdin: bool,
    },
    ResetPassword {
        username: String,
        #[arg(long)]
        password_stdin: bool,
    },
    /// Offline backup: stop the server first. Destination must not exist.
    Backup { destination: PathBuf },
}
fn password(stdin: bool) -> anyhow::Result<String> {
    let password = if stdin {
        let mut value = String::new();
        std::io::stdin().take(1026).read_to_string(&mut value)?;
        value.trim_end_matches(['\r', '\n']).to_owned()
    } else {
        rpassword::prompt_password("Password (at least 12 bytes): ")?
    };
    anyhow::ensure!(
        (12..=1024).contains(&password.len()),
        "password must be 12–1024 bytes"
    );
    Ok(password)
}
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "yun_server=info,tower_http=info".into()),
        )
        .init();
    let cli = Cli::parse();
    let mut config = Config::new(cli.data_dir);
    if let Command::Serve {
        max_file_bytes,
        quota_bytes,
        ..
    } = &cli.command
    {
        config.max_file_bytes = *max_file_bytes;
        config.quota_bytes = *quota_bytes;
    }
    let state = AppState::open(config).await?;
    match cli.command {
        Command::CreateUser {
            username,
            password_stdin,
        } => {
            let user =
                yun_server::create_user(&state, &username, &password(password_stdin)?).await?;
            println!("Created user {username} ({user})");
        }
        Command::ResetPassword {
            username,
            password_stdin,
        } => {
            yun_server::reset_password(&state, &username, &password(password_stdin)?).await?;
            println!("Password reset; all sessions revoked for {username}");
        }
        Command::Backup { destination } => {
            state.backup(&destination).await?;
            println!("Backup written to {}", destination.display());
        }
        Command::Serve {
            bind,
            behind_tls_proxy,
            insecure_loopback,
            ..
        } => {
            anyhow::ensure!(
                behind_tls_proxy || (bind.ip().is_loopback() && insecure_loopback),
                "HTTPS is required: use --behind-tls-proxy with a trusted HTTPS proxy, or explicitly enable --insecure-loopback for development"
            );
            state.cleanup().await?;
            let cleanup_state = state.clone();
            let cleanup = tokio::spawn(async move {
                let mut interval = tokio::time::interval(Duration::from_secs(3600));
                loop {
                    interval.tick().await;
                    if let Err(error) = cleanup_state.cleanup().await {
                        tracing::error!(%error,"storage cleanup failed");
                    }
                }
            });
            let listener = tokio::net::TcpListener::bind(bind).await?;
            tracing::info!(%bind,"Yun server listening; one process per data directory");
            axum::serve(listener, yun_server::router(state.clone()))
                .with_graceful_shutdown(shutdown())
                .await?;
            cleanup.abort();
            let _ = cleanup.await;
        }
    }
    state.close().await;
    Ok(())
}
async fn shutdown() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler");
        tokio::select! { _=tokio::signal::ctrl_c()=>{}, _=term.recv()=>{} }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
