import Foundation

public enum PhysicalDesignReviewGateStatus: String, Sendable, Hashable, Codable {
    case readyForReview = "ready_for_review"
    case approved
    case rejected
    case blocked
    case readyToResume = "ready_to_resume"
}
