import SwiftUI

/// Runs the 52-question evaluation on this iPhone with the selected AI provider.
struct AnswerEvaluationView: View {
    let model: AppModel

    var body: some View {
        let runner = model.evaluation
        Form {
            Section {
                LabeledContent("Provider", value: model.aiProvider.name)
                LabeledContent("Status", value: model.aiProvider.status.label)
                if runner.running {
                    ProgressView(value: Double(runner.rows.count), total: Double(EvaluationItem.all.count)) {
                        Text("\(runner.rows.count)/\(EvaluationItem.all.count)")
                    }
                    Button("Cancel", role: .destructive) { runner.cancel() }
                } else {
                    Button("Run \(EvaluationItem.all.count)-question evaluation") { model.runEvaluation() }
                }
            } footer: {
                Text("Measured on this device with the real pipeline: routing, calculator, model and validation. Keep the app in the foreground; model questions can take a few seconds each.")
            }
            if runner.history.count > 1 {
                Section("Comparison (runs on this device)") {
                    ForEach(runner.history.keys.sorted(), id: \.self) { name in
                        Text(runner.history[name] ?? "").font(.caption.monospaced())
                    }
                }
            }
            Section("Results") {
                Text(runner.summary).font(.callout.monospaced())
                if !runner.rows.isEmpty { ShareLink("Export full report", item: runner.report) }
            }
            Section("Answers") {
                ForEach(runner.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.passed ? "✓" : "✗") \(row.question)").font(.caption.weight(.semibold))
                        Text("\(row.category.rawValue) · \(String(format: "%.2fs", row.seconds)) · \(row.answer)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Answer Evaluation")
    }
}
