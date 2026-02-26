# clud

`clud` is a lightweight tool that turns natural language into ready-to-run shell commands using an LLM.

It is designed for fast terminal workflows with a safety step before execution.

## Features

- Natural language to shell command
- Interactive setup (`--setup`)
- Install as a global command (`--install`)
- BYOK model access (Bring Your Own Key)
- Supports Gemini, Claude, and OpenAI (Codex/GPT models)
- Always asks for confirmation before running the generated command

## Requirements

- `bash`
- `curl`
- `python3`

## Quick Start (Try It Locally)

Run directly from the repo:

```bash
sh clud.sh
```

Then run setup when prompted (or explicitly with `sh clud.sh -s`) and provide your API key.

## Install

Install with interactive path/name confirmation:

```bash
sudo sh clud.sh -i
```

Installing will put clud.sh in PATH as an executable and default to reading config from `~/.clud.env`.

## Usage

```bash
clud <your task>
```

`clud` will always confirm before executing:

```bash
> clud convert file movie.mov to h264 optimized for web and write to out.mp4
Suggested command:
  ffmpeg -i movie.mov -c:v libx264 -preset medium -crf 23 -c:a aac -b:a 128k out.mp4

Run it? [y/N]
```

More examples:

```bash
clud list files sorted by size
clud find all .log files modified in last 24 hours
clud show top 10 processes by memory usage
```

## Configuration

`clud` uses environment-style config files to store settings and API keys.

Read order:

1. `CLUD_CONFIG` (Environment variable)
2. `./.clud.env` 
3. `~/.clud.env`

## Flags

- `-h`, `--help` — show help
- `-s`, `--setup` — run interactive setup
- `-i`, `--install` — install globally
- `--doctor` — check dependencies and config health

## BYOK (Bring Your Own Key)

No need for more subscriptions. Use your own API key.

Supported providers:

- Google Gemini
- Anthropic Claude
- OpenAI ChatGPT

## Safety Note

Read all suggested commands before executing, and in case of uncertainty, run it on someone else's computer first.