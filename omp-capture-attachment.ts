import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export default function (omp: any) {
  const directory = process.env.OMP_OVERLAY_CAPTURE_DIR;
  if (!directory) return;
  const formats = ["png", "jpg", "webp", "gif", "reference"];
  const receipt = join(directory, "receipt");
  let timer: ReturnType<typeof setInterval> | undefined;
  let busy = false;

  function remove(file: string) {
    try { unlinkSync(file); } catch {}
  }

  omp.on("session_start", (_event: unknown, ctx: any) => {
    if (!ctx.hasUI || !ctx.ui.pasteToEditor) return;
    if (timer) clearInterval(timer);
    timer = setInterval(async () => {
      if (busy) return;
      const format = formats.find(ext => existsSync(join(directory, "capture." + ext)));
      if (!format) return;
      const incoming = join(directory, "capture." + format);
      const attaching = join(directory, "attachment." + format);
      busy = true;
      let attached = false;
      try {
        renameSync(incoming, attaching);
        if (format === "reference") {
          const path = readFileSync(attaching, "utf8");
          const mention = `@"${path}"`;
          const before = ctx.ui.getEditorText();
          ctx.ui.pasteToEditor(` ${mention} `);
          const after = ctx.ui.getEditorText();
          attached = after !== before && after.includes(mention);
          return;
        }
        // getEditorText returns compact chip labels, not their submit-time expansion.
        const markers = (text: string) => text.match(/#\d+\b/g)?.length ?? 0;
        const before = markers(ctx.ui.getEditorText());
        ctx.ui.pasteToEditor(attaching.replaceAll("\\", "/"));
        for (let attempt = 0; attempt < 35; attempt++) {
          await new Promise(resolve => setTimeout(resolve, 100));
          if (markers(ctx.ui.getEditorText()) > before) {
            attached = true;
            break;
          }
        }
      } catch {
        // The host shows a failure status without sending the user's draft.
      } finally {
        remove(attaching);
        try { writeFileSync(receipt, attached ? "ok" : "failed"); } catch {}
        busy = false;
      }
    }, 150);
    timer.unref();
  });
  omp.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
  });
}
