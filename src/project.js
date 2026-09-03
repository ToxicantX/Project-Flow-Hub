(() => {
  const project = JSON.parse(document.querySelector("#project-data").textContent);
  const nav = document.querySelector("#flow-nav");
  const viewer = document.querySelector("#viewer");
  const title = document.querySelector("#current-title");
  const filename = document.querySelector("#current-file");
  const openCurrent = document.querySelector("#open-current");
  let observer;

  function resizeViewer() {
    const root = viewer.contentDocument?.documentElement;
    const body = viewer.contentDocument?.body;
    if (!root || !body) return;
    const height = Math.ceil(Math.max(root.scrollHeight, body.scrollHeight));
    if (height > 0 && Math.abs(viewer.offsetHeight - height) > 1) viewer.style.height = `${height}px`;
  }

  viewer.addEventListener("load", () => {
    observer?.disconnect();
    observer = new ResizeObserver(() => requestAnimationFrame(resizeViewer));
    observer.observe(viewer.contentDocument.documentElement);
    observer.observe(viewer.contentDocument.body);
    resizeViewer();
    viewer.contentDocument?.fonts?.ready.then(resizeViewer);
  });

  function selectFlow(flow, updateHash = true) {
    observer?.disconnect();
    viewer.style.height = "720px";
    viewer.src = flow.file;
    title.textContent = `${flow.id} · ${flow.title}`;
    filename.textContent = flow.file;
    openCurrent.href = flow.file;
    document.title = `${flow.title} · ${project.title}`;
    nav.querySelectorAll("button").forEach((button) => {
      button.setAttribute("aria-current", button.dataset.id === flow.id ? "page" : "false");
    });
    if (updateHash) history.replaceState(null, "", `#${flow.id}`);
  }

  for (const flow of project.flows) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "flow-link";
    button.dataset.id = flow.id;
    const index = document.createElement("span");
    index.className = "flow-index";
    index.textContent = flow.id;
    const label = document.createElement("span");
    label.className = "flow-label";
    label.textContent = flow.title;
    button.append(index, label);
    button.addEventListener("click", () => selectFlow(flow));
    nav.appendChild(button);
  }

  window.addEventListener("resize", () => requestAnimationFrame(resizeViewer));
  const initial = project.flows.find((flow) => flow.id === location.hash.slice(1)) || project.flows[0];
  selectFlow(initial, false);
})();
