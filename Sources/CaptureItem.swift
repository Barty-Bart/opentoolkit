import Foundation

struct CaptureItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let date: Date
    init(url: URL, date: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.url = url; self.date = date
    }
}

