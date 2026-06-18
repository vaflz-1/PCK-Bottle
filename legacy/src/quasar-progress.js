const host = document.querySelector("#q-progress-host");

if (host && window.Vue && window.Quasar) {
  const { createApp, h, ref } = window.Vue;
  const {
    QBadge,
    QCard,
    QCardSection,
    QDialog,
    QLinearProgress,
    QSeparator,
  } = window.Quasar;
  const progress = ref(null);

  window.addEventListener("pack-progress-change", (event) => {
    progress.value = event.detail ?? null;
  });

  createApp({
    setup() {
      const counter = (label, value, color) =>
        h("div", { class: "qps-counter" }, [
          h("strong", String(value)),
          h(QBadge, { color, outline: true, label }),
        ]);

      return () =>
        h(QDialog, { modelValue: Boolean(progress.value), persistent: true }, () =>
          h(QCard, { class: "qps-card" }, () => {
            const current = progress.value ?? {};
            const percent = Number(current.percent ?? 0);
            return [
              h(QCardSection, { class: "qps-head" }, () => [
                h("div", [
                  h("div", { class: "text-overline text-primary" }, current.kicker ?? ""),
                  h("div", { class: "text-h6" }, current.title ?? ""),
                ]),
                h("strong", `${percent}%`),
              ]),
              h(QCardSection, { class: "q-pt-none" }, () => [
                h("p", { class: "qps-message" }, current.message ?? ""),
                h(QLinearProgress, {
                  class: "q-mt-md",
                  color: "primary",
                  rounded: true,
                  size: "12px",
                  value: percent / 100,
                }),
              ]),
              h(QSeparator),
              h(QCardSection, { class: "qps-grid" }, () => [
                counter(current.addLabel ?? "Add", current.addCount ?? 0, "teal"),
                counter(current.replaceLabel ?? "Replace", current.replaceCount ?? 0, "orange"),
                counter(current.totalLabel ?? "Total", current.sizeLabel ?? "0 B", "blue"),
              ]),
              h(QCardSection, { class: "q-pt-none qps-backup" }, () => current.backupLabel ?? ""),
            ];
          }),
        );
    },
  })
    .use(window.Quasar)
    .mount(host);
}
