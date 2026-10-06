import Foundation
import Testing
@testable import twodos___ios

/// The partner directory, sent invitations, attachments, and the words the app
/// uses for who is doing what.
///
/// The JSON here follows the `@openapi` examples in
/// `backend/src/routers/api/v1/` rather than captured traffic — these endpoints
/// had no client before this one. Replace them with real captures when there
/// are some.
@Suite("Partner directory and attachments")
struct PartnerDirectoryTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIDecodingTests.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Directory

    @Test("The directory decodes counts and every relationship state")
    func directoryDecodes() throws {
        let json = """
        {"counts":{"total":3,"accepted":1,"pending":1,"rejected":0,"blocked":1,"withLists":1},
         "partners":[
          {"id":"a","name":"Sara Khan","username":"sara_k","email":"sara@example.com","avatarUrl":null,
           "status":"TODOS::INVITE_STATUS::ACCEPTED","hasLists":true,"listCount":3,"acceptedListCount":2,
           "pendingListCount":1,"blocked":false,"blockedByThem":false,
           "lastActivityAt":"2026-10-01T09:00:00.000Z"},
          {"id":"b","name":null,"username":null,"email":"sam@example.com",
           "status":"TODOS::INVITE_STATUS::PENDING","hasLists":false,"listCount":1,
           "acceptedListCount":0,"pendingListCount":1,"blocked":false,"blockedByThem":false},
          {"id":"c","name":"Jo","username":"jo","email":null,"avatarUrl":null,"status":null,
           "hasLists":false,"listCount":0,"acceptedListCount":0,"pendingListCount":0,
           "blocked":false,"blockedByThem":true}
         ]}
        """
        let directory = try decode(PartnerDirectory.self, json)

        #expect(directory.counts.total == 3)
        #expect(directory.counts.withLists == 1)
        #expect(directory.partners.count == 3)

        let sara = directory.partners[0]
        #expect(sara.isAccepted && sara.hasLists && sara.acceptedListCount == 2)

        let sam = directory.partners[1]
        #expect(sam.isPending && !sam.hasLists)

        // Redacted, not missing: the email is null and the decode still holds.
        let jo = directory.partners[2]
        #expect(jo.blockedByThem && jo.isInBlock)
        #expect(jo.email.isEmpty)
        #expect(jo.status == nil)
    }

    @Test("The older partners payload still decodes, with nothing blocked")
    func legacyPartnerDefaults() throws {
        let partner = try decode(Partner.self, """
        {"id":"x","name":"Sam","email":"sam@example.com","status":"TODOS::INVITE_STATUS::ACCEPTED"}
        """)
        #expect(!partner.blocked && !partner.blockedByThem && partner.listCount == 0)
    }

    // MARK: - Naming

    @Test("Who is doing it reads handle, then name, then address")
    func identityLabelOrder() {
        let withHandle = Partner(id: "1", name: "Sara", email: "sara@example.com", username: "sara_k")
        let withName = Partner(id: "2", name: "Jo Bennett", email: "jo@example.com")
        let addressOnly = Partner(id: "3", name: nil, email: "sam@example.com")

        #expect(withHandle.identityLabel == "@sara_k")
        #expect(withName.identityLabel == "Jo Bennett")
        #expect(addressOnly.identityLabel == "sam@example.com")
    }

    @Test("A partner who blocked you is still named by their handle")
    func redactedPartnerHasAName() {
        let redacted = Partner(id: "4", name: nil, email: "", username: "jo")
        #expect(redacted.displayName == "@jo")
        #expect(!redacted.identityLabel.isEmpty)
    }

    @Test("No relationship state is described as 'someone'")
    func counterpartNeverSaysSomeone() {
        let states: [ListCounterpart.State] = [
            .accepted, .awaitingThem, .awaitingYou, .declined, .youBlocked, .blockedYou
        ]
        for state in states {
            for name in [Optional("@sam"), nil] {
                let text = ListCounterpart(partner: nil, name: name, state: state).statusText
                #expect(!text.isEmpty)
                #expect(!text.localizedCaseInsensitiveContains("someone"))
                if let name { #expect(text.contains(name)) }
            }
        }
    }

    // MARK: - Sent invitations

    @Test("A sent invitation to someone with an account never expires")
    func sentInviteExpiry() throws {
        let invites = try decode([SentInvite].self, """
        [{"listId":"l1","label":"Groceries","invitedAt":"2026-10-01T09:00:00.000Z",
          "invitee":{"id":"u1","name":null,"username":null,"email":"sam@example.com","hasAccount":false},
          "expiresAt":"2026-10-08T09:00:00.000Z","reminderSentAt":null,"blocked":false,"canResend":true},
         {"listId":"l2","label":"Trip","invitedAt":"2026-10-02T09:00:00.000Z",
          "invitee":{"id":"u2","name":"Jo","username":"jo","email":"jo@example.com","hasAccount":true},
          "expiresAt":null,"reminderSentAt":null,"blocked":false,"canResend":false}]
        """)
        #expect(invites[0].expiresAt != nil && invites[0].invitee.hasAccount == false)
        #expect(invites[0].invitee.identityLabel == "sam@example.com")
        #expect(invites[1].expiresAt == nil && invites[1].invitee.hasAccount)
        #expect(invites[1].invitee.identityLabel == "@jo")
    }

    // MARK: - Attachments

    @Test("A task carries its attachments and the list its allowance")
    func listWithMedia() throws {
        let list = try decode(TodoList.self, """
        {"id":"l1","label":"Receipts","createdBy":"me","partnerId":"them","inviteAccepted":true,
         "mediaAllowance":{"enabled":true,"maxFileBytes":5242880,"filesPerTask":2,"filesPerList":10,
           "bytesPerList":104857600,"remainingOnList":9,"remainingBytesOnList":104809387},
         "items":[{"id":"t1","listId":"l1","title":"Lunch","done":false,"order":0,"mediaRemaining":1,
           "media":[{"id":"m1","todoId":"t1","listId":"l1","uploadedBy":"me","fileName":"receipt.pdf",
             "declaredContentType":"application/pdf","sniffedContentType":"application/pdf",
             "contentTypeMismatch":false,"sizeBytes":48213,"kind":"MEDIA::KIND::DOCUMENT",
             "createdAt":"2026-10-01T09:00:00.000Z","url":"/api/v1/media/m1"}]}]}
        """)
        #expect(list.mediaAllowance?.filesPerTask == 2)
        #expect(list.todos[0].media.count == 1)
        #expect(list.todos[0].mediaRemaining == 1)
        #expect(list.todos[0].media[0].kind == .document)
        #expect(!list.todos[0].media[0].isPreviewableImage)
    }

    @Test("An image whose bytes disagree with its name is not previewed")
    func mismatchIsNotPreviewed() throws {
        let media = try decode(TodoMedia.self, """
        {"id":"m2","todoId":"t1","listId":"l1","fileName":"photo.png","declaredContentType":"image/png",
         "sniffedContentType":null,"contentTypeMismatch":true,"sizeBytes":10,"kind":"MEDIA::KIND::IMAGE"}
        """)
        #expect(media.kind == .image)
        #expect(!media.isPreviewableImage)
    }

    @Test("A server without attachments leaves every task empty and the list without an allowance")
    func noMediaFields() throws {
        let list = try decode(TodoList.self, """
        {"id":"l1","label":"Old","items":[{"id":"t1","title":"Milk"}]}
        """)
        #expect(list.mediaAllowance == nil)
        #expect(list.todos[0].media.isEmpty)
        #expect(list.todos[0].mediaRemaining == nil)
    }
}
