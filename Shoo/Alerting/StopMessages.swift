import Foundation

/// A pool of cheeky one-line reminders shown as the overlay subtitle. One is picked at
/// random each time the reminder appears so it stays fresh instead of nagging identically.
enum StopMessages {
    static let all: [String] = [
        "Nope, not today.",
        "Your face is fine, leave it alone.",
        "Caught you red-handed.",
        "Step away from the face.",
        "That's a no from your face.",
        "Mitts off, friend.",
        "Face is closed for business.",
        "Did the face do something to you?",
        "Hand. Down. Now.",
        "Resist the urge, champ.",
        "Your nails called. They want a break.",
        "Not a snack.",
        "Personal space — even for your own face.",
        "We talked about this.",
        "Busted.",
        "The face says: hands off.",
        "Easy there, fidget fingers.",
        "Abort the mission.",
        "Put the hand back.",
        "This is your face speaking. Stop.",
        "Nuh-uh.",
        "Keep those paws to yourself.",
        "Face touching: denied.",
        "You good? Hand's getting awfully close.",
        "Not the nails again.",
        "Retreat!",
        "Hands belong on the keyboard.",
        "Spotted you.",
        "Your skin will thank you later.",
        "Cease and desist.",
        "Face is not a stress ball.",
        "Down, fingers, down.",
        "I saw that.",
        "Leave the poor face alone.",
        "Hand check failed.",
        "Pull it back, you've got this.",
        "Nope nope nope.",
        "The face has had enough.",
        "Quit it, you legend.",
        "Drop the hand.",
        "No nibbling.",
        "Your future self is watching.",
        "Hands: redirect.",
        "That itch can wait.",
        "Faces are for looking, not poking.",
        "Hold up, partner.",
        "Hand-to-face ratio too high.",
        "Be strong. Hands down.",
        "Not on my watch.",
        "Give the face a day off.",
    ]

    /// A random message, with a safe fallback if the pool is ever empty.
    static func random() -> String {
        all.randomElement() ?? "Hands away from your face"
    }
}
