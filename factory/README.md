# factory

The `factory/` directory contains the task runner and supporting scripts for
the Dark Factory pipeline.

## Task input

A task is expressed as two environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `TASK`   | yes      | A natural-language prompt describing the work to perform |
| `REPO`   | no       | A git repository URL the task should operate on |

Pass them through `make run`:

```sh
make run TASK="add a README to the project"
make run TASK="fix the failing tests" REPO="https://git.example.com/org/repo.git"
```

## Run directory

Each invocation creates a timestamped directory under `runs/`:

```
runs/
  20240601T120000Z/   ← artifacts from one invocation
  20240601T130000Z/   ← artifacts from the next
```

The `runs/` tree is excluded from source control. Artifact layout within a
run directory is defined by the individual stages as they are implemented.

## Pipeline stages

`run.sh` calls four stages in order:

1. **provision** — prepare an isolated dev container for the task
2. **execute** — invoke the AI agent with the task prompt inside the container
3. **collect** — gather artifacts from the container into the run directory
4. **teardown** — discard or archive the container

Each stage is an independent shell function. Replace the body of a stage to
add real behaviour without touching the others.
