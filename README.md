# VSH — Virtual Shell Archive System

A client-server archive system built in Bash as part of the **LO14** module at UTT (Université de Technologie de Troyes). VSH simulates a remote shell environment, allowing clients to manage archived files on a server over a TCP connection.

---

## Overview

VSH is split into two components:

- **`vsh`** — the client, used to send commands to the server
- **`vsh-server`** — the server, which handles incoming connections and manages the archive

Communication happens over TCP. The client connects to the server, sends commands, and receives responses — mimicking a lightweight remote shell for file archive management.

---

## Features

- Remote file archiving over a TCP connection
- Supported commands:
  - `LIST` — list files currently stored in the archive
  - `CREATE` — add a new file to the archive
  - `GET` — retrieve a file from the archive
  - `UPDATE` — update the contents of an existing archived file
- Client-server architecture with persistent server process
- Implemented entirely in Bash (no compiled languages)

---

## Project Structure

```
Projet_LO14/
├── vsh              # Client script
└── vsh-server       # Server script
```

---

## Usage

### Start the server

```bash
./vsh-server <port>
```

The server listens on the specified TCP port for incoming client connections.

### Connect with the client

```bash
./vsh <host> <port>
```

Once connected, you can run archive commands interactively.

### Example session

```
$ ./vsh localhost 4242
> LIST
archive/
archive/notes.txt
archive/report.pdf

> GET notes.txt
[file content received]

> CREATE newfile.txt
[file uploaded to archive]
```

---

## Requirements

- Bash (version 4.0+)
- Standard Unix utilities (`netcat` / `nc` for TCP communication)
- Linux or macOS environment

---

## Context

This project was developed as part of the **LO14 — Unix Systems and Shell Programming** module at UTT. The goal was to apply shell scripting skills to build a real client-server application, covering:

- TCP socket communication in Bash
- Process and file management
- Command parsing and protocol design

---

## Author

Farhan — UTT Engineering Student
