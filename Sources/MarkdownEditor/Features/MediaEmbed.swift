import Foundation

struct MediaEmbed: Equatable {
  enum Kind: Equatable { case video, audio, iframe }
  var kind: Kind
  var source: String
  var width: CGFloat?
  var height: CGFloat?
  static func parse(_ html: String) -> MediaEmbed? { nil }
}
