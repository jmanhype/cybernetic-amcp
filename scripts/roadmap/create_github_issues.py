#!/usr/bin/env python3
"""
Create GitHub issues from blackbox_roadmap_with_backlog.json using GitHub CLI.

Prereqs:
- Install GitHub CLI: https://cli.github.com/
- Authenticate: `gh auth login`

Usage:
  python3 scripts/roadmap/create_github_issues.py --repo owner/name
  # or set GH repo via env: export GH_REPO=owner/name
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Any


def find_repo_root(start: Path) -> Path:
    cur = start.resolve()
    while cur != cur.parent:
        if (cur / "blackbox_roadmap_with_backlog.json").exists():
            return cur
        cur = cur.parent
    return start.resolve()


def load_tasks(repo_root: Path) -> List[Dict[str, Any]]:
    """Load and normalize tasks from blackbox_roadmap_with_backlog.json.

    Args:
        repo_root: Path to repository root containing the JSON file

    Returns:
        List of normalized task dictionaries

    Raises:
        FileNotFoundError: If the roadmap JSON file doesn't exist
        json.JSONDecodeError: If the JSON file is malformed
    """
    src = repo_root / "blackbox_roadmap_with_backlog.json"
    try:
        with src.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"Error: {src} not found", file=sys.stderr)
        raise
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in {src}: {e}", file=sys.stderr)
        raise

    tasks = data.get("tasks", data)
    for t in tasks:
        if not isinstance(t, dict):
            continue
        # Normalize fields and legacy typos
        t.setdefault("description", t.get("desc") or t.get("desciptio") or "")
        t.setdefault("phase", "Unassigned")
        t.setdefault("status", "To Do")
    return [t for t in tasks if isinstance(t, dict) and t.get("title")]


def main() -> int:
    """Main entry point for GitHub issue creation.

    Returns:
        Exit code: 0 for success, 1 for failure
    """
    parser = argparse.ArgumentParser(
        description="Create GitHub issues from blackbox_roadmap_with_backlog.json"
    )
    parser.add_argument("--repo", default=os.getenv("GH_REPO"), help="owner/name repository slug")
    parser.add_argument("--dry-run", action="store_true", help="print commands without creating issues")
    args = parser.parse_args()

    try:
        repo_root = find_repo_root(Path(__file__).parent)
        tasks = load_tasks(repo_root)
        if not tasks:
            print("No tasks found.")
            return 1

        # Validate gh CLI is available
        try:
            subprocess.run(["gh", "--version"], check=True, capture_output=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            print("Error: GitHub CLI (gh) not found. Install from https://cli.github.com/", file=sys.stderr)
            return 1

        if not args.repo and not args.dry_run:
            print("Error: --repo must be specified or GH_REPO environment variable set", file=sys.stderr)
            return 1

        base_cmd = ["gh", "issue", "create"]
        if args.repo:
            base_cmd += ["--repo", args.repo]

        created = 0
        for t in tasks:
            title = t["title"].strip()
            body = (t.get("description") or "Imported from roadmap.").strip()
            labels = [f"phase:{t.get('phase','Unassigned')}", f"status:{t.get('status','To Do')}"]
            cmd = base_cmd + ["--title", title, "--body", body, "--label", ",".join(labels)]
            if args.dry_run:
                print("DRY:", " ".join(cmd))
                continue
            try:
                subprocess.run(cmd, check=True, capture_output=True)
                created += 1
                print(f"Created issue: {title}")
            except subprocess.CalledProcessError as e:
                print(f"Failed to create issue for '{title}': {e}", file=sys.stderr)

        print(f"Done. Created {created} issues.")
        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

