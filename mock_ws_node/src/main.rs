use futures_util::stream::StreamExt;
use std::net::SocketAddr;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::handshake::server::{Request as WSRequest, Response as WSResponse};

const CRUD_URL: &str = "http://127.0.0.1:8081/status";

#[tokio::main]
async fn main() {
    let ws_addr = "127.0.0.1:8080";
    let listener = TcpListener::bind(ws_addr).await.expect("Failed to bind port 8080");
    println!("🦀 Rust Mock Server running on {}!", ws_addr);

    let http = reqwest::Client::new(); // one client, cloned cheaply per connection

    while let Ok((stream, addr)) = listener.accept().await {
        tokio::spawn(handle_connection(stream, addr, http.clone()));
    }
}

async fn send_log(http: &reqwest::Client, turtle_id: &str, status: &str) {
    let url = match reqwest::Url::parse_with_params(
        CRUD_URL,
        &[("turtleId", turtle_id), ("status", status)],
    ) {
        Ok(u) => u,
        Err(e) => return eprintln!("[WS] Bad log URL: {e}"),
    };

    let result = http
        .post(url)
        .send()
        .await
        .and_then(|r| r.error_for_status());

    match result {
        Ok(r) => println!("[WS] Logged to CRUD server: {}", r.text().await.unwrap_or_default()),
        Err(e) => eprintln!("[WS] Failed to log to CRUD server: {e}"),
    }
}

async fn handle_connection(stream: TcpStream, addr: SocketAddr, http: reqwest::Client) {
    let mut turtle_id: Option<String> = None;

    let ws_stream = match tokio_tungstenite::accept_hdr_async(
        stream,
        |request: &WSRequest, response: WSResponse| {
            // Sync callback: just capture the header, no network calls here
            turtle_id = request
                .headers()
                .get("turtle_id")
                .and_then(|v| v.to_str().ok())
                .map(str::to_owned);
            Ok(response)
        },
    )
    .await
    {
        Ok(ws) => ws,
        Err(e) => {
            eprintln!("[WS] Handshake failed with {addr}: {e}");
            return;
        }
    };

    let id = turtle_id.unwrap_or_else(|| "unknown".into());
    println!("[WS] Turtle {id} connected from {addr}");
    send_log(&http, &id, "Connected").await;

    let (_write, mut read) = ws_stream.split();
    while let Some(Ok(msg)) = read.next().await {
        if msg.is_text() || msg.is_binary() {
            println!("[WS Message] Turtle {id}: {}", msg.to_text().unwrap_or_default());
        }
    }

    println!("[WS] Turtle {id} disconnected.");
    send_log(&http, &id, "Disconnected").await;
}