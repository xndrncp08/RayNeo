import Testing
@testable import RayNeoInterviewCompanion

@Suite struct QuestionDetectionTests {
    let detector = QuestionDetector(technicalKeywords: KnowledgeBase.defaultTopics.flatMap(\.keywords))

    @Test(arguments: [
        "What is the difference between async and await?",
        "How would you investigate a failed Salesforce integration?",
        "How do you troubleshoot a Microsoft 365 login issue?",
        "What would you do if the internet failed during a classroom exam?",
        "Explain how Row Level Security works.",
        "Walk me through how you built your messaging platform.",
        "How would you design a database for tracking student enrollment?",
        "Tell me about a project you developed.",
        "Describe how you would solve this problem.",
        "Walk me through your troubleshooting process.",
        "Show me how you would debug this API.",
        "So, can you tell me how you handle a 500 error",
        "Okay, explain what a left join returns",
    ])
    func detectsQuestionsAndRequests(_ text: String) {
        let result = detector.analyze(text)
        #expect(result.score >= 0.5, "\(text) scored \(result.score): \(result.reason)")
    }

    @Test(arguments: [
        "Um yeah okay",
        "That makes sense.",
        "Right, right.",
        "We use Salesforce here.",
        "I think that's great.",
        "Thanks for coming in today.",
        "What is the difference between",
        "How would you investigate the",
        "So tell me about",
    ])
    func rejectsFillerStatementsAndIncompleteQuestions(_ text: String) {
        let result = detector.analyze(text)
        #expect(result.score < 0.5, "\(text) scored \(result.score): \(result.reason)")
    }

    @Test func detectsFollowUps() {
        let followUp = detector.analyze("And what about the performance impact?", previousQuestion: "Explain how indexes work.")
        #expect(followUp.isFollowUp)
        #expect(!detector.analyze("What is a REST API?", previousQuestion: "Explain how indexes work.").isFollowUp)
    }

    @Test func wearerReadingAnswerOverlapsStrongly() {
        let answer = "First, I would check the API logs and verify whether the request is reaching the backend. Then I would compare the payload."
        #expect(TextSimilarity.containment("First, I would check the API logs and verify whether the request is reaching the backend", in: answer) > 0.9)
        #expect(TextSimilarity.containment("so I'd look at the API logs to see if requests reach the backend", in: answer) >= 0.5)
        #expect(TextSimilarity.containment("How would you design a database for student enrollment?", in: answer) < 0.3)
    }
}
