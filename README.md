# homelab-gitops-apps

Applications for the StaffOps homelab platform: one helmfile directory per app, deployed by Argo CD from
[homelab-gitops](https://github.com/StaffOps/homelab-gitops) (ApplicationSet `apps`, AppProject `apps`).

```
<app>/helmfile.yaml.gotmpl     one app = one namespace
<app>/<release>/               one directory per helmfile release = one Argo CD Application
_template/                     starting point for a new app (skipped by Argo CD)
environment.yaml               platform contract (domain, gateway, storage class)
scripts/render-app.sh          render and check an app like Argo CD does
```

New app: `cp -R _template <app>`, replace `my-app`, `scripts/render-app.sh <app>`, commit, push. Rules for humans
and agents: [AGENTS.md](AGENTS.md).

Requires `helmfile`, `helm` and `yq`.

## License

[MIT-0](LICENSE): use, copy, modify and redistribute freely, no attribution required, no warranty.
