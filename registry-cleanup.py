#!/usr/bin/env python3
"""
Keep only the last KEEP dev builds per image, delete older ones, run GC.
Usage: REGISTRY_PASS=xxx python3 registry-cleanup.py
"""
import json
import os
import subprocess
from base64 import b64encode
from urllib import request as urllib_req
from urllib.error import HTTPError

REGISTRY = "http://127.0.0.1:5000"
USER = "admin"
PASS = os.environ["REGISTRY_PASS"]
IMAGES = ["wyunsi/server", "wyunsi/worker"]
KEEP = 5  # 保留最近几个 dev 构建

auth = b64encode(f"{USER}:{PASS}".encode()).decode()


def api(method, path, extra_headers=None):
    headers = {"Authorization": f"Basic {auth}", **(extra_headers or {})}
    r = urllib_req.Request(f"{REGISTRY}{path}", headers=headers, method=method)
    try:
        with urllib_req.urlopen(r) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except HTTPError as e:
        return e.code, dict(e.headers), e.read()


for image in IMAGES:
    _, _, body = api("GET", f"/v2/{image}/tags/list")
    tags = json.loads(body).get("tags") or []

    # dev-{run_number}-{sha} 格式，按字母排序即时间顺序
    dev_tags = sorted(t for t in tags if t.startswith("dev-"))
    to_delete = dev_tags[:-KEEP] if len(dev_tags) > KEEP else []

    print(f"{image}: {len(dev_tags)} dev tags, keeping {KEEP}, deleting {len(to_delete)}")

    for tag in to_delete:
        _, headers, _ = api(
            "GET",
            f"/v2/{image}/manifests/{tag}",
            {"Accept": "application/vnd.docker.distribution.manifest.v2+json"},
        )
        digest = headers.get("Docker-Content-Digest", "").strip()
        if digest:
            status, _, _ = api("DELETE", f"/v2/{image}/manifests/{digest}")
            print(f"  deleted {image}:{tag}  [{status}]")

print("\nRunning GC...")
subprocess.run(
    [
        "docker", "exec", "registry",
        "bin/registry", "garbage-collect",
        "/etc/docker/registry/config.yml",
        "--delete-untagged=true",
    ],
    check=True,
)
print("Done.")
