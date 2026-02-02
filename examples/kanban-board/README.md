# Kanban Board Example

This full-stack Kanban board was built entirely by SwarmTool in a single run.

## The Prompt

```bash
swarmtool "Build a Kanban board web app"
```

## What SwarmTool Did

1. **Planner** decomposed the goal into 5 parallel tasks
2. **5 Workers** built simultaneously:
   - Backend API with Express
   - Board management UI
   - Column management
   - Card management with modals
   - Drag-and-drop functionality
3. **Judge** evaluated all tasks (13 pass | 0 fail)
4. **Merger** combined everything into working code

## Features Built

- Multiple boards with create/rename/delete
- Columns with drag-and-drop reordering
- Cards with labels, due dates, descriptions
- Custom modal system (no browser alerts)
- Toast notifications
- Full error handling
- Responsive design

## Run It

```bash
cd examples/kanban-board
npm install
npm start
# Open http://localhost:3000
```

## Stats

| Metric | Value |
|--------|-------|
| Workers | 5 (parallel) |
| Tasks | 5 |
| Pass rate | 13/13 (100%) |
| Files created | 12 |
| Lines of code | ~2,000 |
