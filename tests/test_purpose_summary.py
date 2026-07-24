"""Human-facing project purpose blurb."""
from __future__ import annotations

from ide_storage.purpose_summary import build_purpose_summary


def test_samsung_uses_story_not_agent_pickup():
    project = {
        "slug": "samsung-server",
        "description": None,
        "metadata": {
            "where_we_left_off": (
                "corbox-lite in this repo is canonical docker-dashboard Go hub "
                "(phone ARM + Proxmox amd64). Deploy: bin/deploy-hub --phone|--proxmox."
            ),
            "semantic_descriptor": (
                "Samsung Galaxy S4 Active phone server: corbox-sshd at 192.168.1.60:2222, "
                "hub UI http://192.168.1.60:8888, deploy via bin/deploy-hub --phone|--proxmox, "
                "LXC 103 path /opt/corbox-hub, primary_hub sync disabled."
            ),
        },
    }
    text = build_purpose_summary(
        project,
        continue_mode="investigation",
        handoff_tier="orient",
    )
    assert "phone" in text.lower()
    assert "Where we left off" not in text
    assert "Diagnostic or tuning" not in text
    assert "bin/deploy-hub" not in text


def test_logitech_story_reads_like_overview():
    project = {
        "slug": "logitech-g-hub",
        "description": "G502 ownership toolkit",
        "metadata": {
            "where_we_left_off": "Checking the HID DLL path and G HUB process handling next.",
        },
    }
    text = build_purpose_summary(project)
    assert "preset" in text.lower()
    assert "Where we left off" not in text
    assert "HID DLL" not in text


def test_human_overview_override_wins():
    project = {
        "slug": "samsung-server",
        "metadata": {
            "human_overview": (
                "An old Galaxy phone running as a tiny home server for SSH and a backup dashboard."
            ),
        },
    }
    text = build_purpose_summary(project)
    assert "Galaxy phone" in text
    assert "tiny home server" in text
