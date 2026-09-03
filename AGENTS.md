# Project Flow Hub Agent Contract

- Treat `projects/*/project.json` as the source of truth for project and flow navigation.
- Generate diagrams with the Archify skill. Keep the source JSON beside the delivered HTML.
- Before registering a flow, require a successful Archify `validate`, `deliver`, and browser evidence run.
- Run `npm test` and `npm run build` after changing a project manifest, build code, or portal UI.
- Never commit SSH keys, API keys, GitHub tokens, server passwords, `.env` files, or private logs.
- Production deployment is performed only by `.github/workflows/deploy.yml` after an authorized push to `main`.
- For source repositories without a remote default branch, install the versioned local hook instead of inventing a cross-repository token workflow.
- Preserve existing projects and routes. Add or update only the project named in the task.
