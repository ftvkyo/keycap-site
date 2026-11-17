// SPDX-License-Identifier: GPL-3.0-or-later
//
// A button on each code block that copies its code.  The site's only
// script: without it, the code is still there to select and copy.

async function copy(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Without the Clipboard API, as over plain HTTP: through a selection.
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.className = "copy-scratch";
    document.body.append(area);
    area.select();
    const copied = document.execCommand("copy");
    area.remove();
    if (!copied) {
      throw new Error("Could not copy");
    }
  }
}

for (const block of document.querySelectorAll(".org-src-container")) {
  const code = block.querySelector("pre");
  const button = document.createElement("button");
  let timer;

  button.type = "button";
  button.className = "copy";
  button.textContent = "Copy";
  // Read out when it changes to "Copied".
  button.setAttribute("aria-live", "polite");

  button.addEventListener("click", async () => {
    try {
      await copy(code.textContent);
      button.textContent = "Copied";
    } catch {
      // Left to the reader: the code selected, for C-c or the menu.
      getSelection().selectAllChildren(code);
      button.textContent = "Selected";
    }
    button.dataset.state = "done";
    clearTimeout(timer);
    timer = setTimeout(() => {
      button.textContent = "Copy";
      delete button.dataset.state;
    }, 2000);
  });

  block.append(button);
}
