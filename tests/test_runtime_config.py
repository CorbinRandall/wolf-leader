from ide_storage.runtime_config import runtime_config


def test_runtime_defaults_are_safe(monkeypatch):
    for name in (
        "IDE_STORAGE_PUBLIC_HOST", "IDE_STORAGE_PUBLIC_URL", "IDE_STORAGE_LOCAL_URL",
        "IDE_STORAGE_MCP_URL", "IDE_STORAGE_DEVICE_NAME", "IDE_STORAGE_HOST_LABEL",
        "PORT", "MCP_PORT",
    ):
        monkeypatch.delenv(name, raising=False)
    cfg = runtime_config()
    assert cfg.public_url == "http://127.0.0.1:6971"
    assert cfg.mcp_url == "http://127.0.0.1:6972/mcp"


def test_runtime_uses_device_and_public_host(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_PUBLIC_HOST", "100.112.113.15")
    monkeypatch.setenv("IDE_STORAGE_DEVICE_NAME", "moto")
    monkeypatch.delenv("IDE_STORAGE_PUBLIC_URL", raising=False)
    monkeypatch.delenv("IDE_STORAGE_MCP_URL", raising=False)
    cfg = runtime_config()
    assert cfg.device_name == "moto"
    assert cfg.public_url == "http://100.112.113.15:6971"
    assert cfg.mcp_url == "http://100.112.113.15:6972/mcp"


def test_explicit_urls_win(monkeypatch):
    monkeypatch.setenv("IDE_STORAGE_PUBLIC_HOST", "moto.example")
    monkeypatch.setenv("IDE_STORAGE_PUBLIC_URL", "https://wolf.example/")
    monkeypatch.setenv("IDE_STORAGE_MCP_URL", "https://mcp.example/mcp/")
    cfg = runtime_config()
    assert cfg.public_url == "https://wolf.example"
    assert cfg.mcp_url == "https://mcp.example/mcp"
