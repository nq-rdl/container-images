## Description

<!-- What does this PR change and why? -->

## Checklist

- [ ] Containerfile uses a UBI base image
- [ ] Non-root `USER` directive present
- [ ] All required OCI labels present
- [ ] `image.yaml` metadata is accurate
- [ ] `pixi run lint-all` passes locally
- [ ] Image builds locally (`podman build images/<name>/`)
- [ ] README updated (if adding/changing an image)
- [ ] Dependabot entry added (if new image)
