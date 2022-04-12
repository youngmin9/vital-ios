public enum Brand: Equatable {
  case omron
  case accuChek
  case contour
  case beurer
  
  public var name: String {
    switch self {
      case .contour:
        return "Contour"
      case .omron:
        return "Omron"
      case .accuChek:
        return "Accu-Chek"
    case .beurer:
        return "Beurer"
    }
  }
}

public struct DeviceModel: Equatable, Identifiable {
  public let name: String
  public let kind: Kind
  public let brand: Brand

  public let id: String
  let codes: [String]
  
  init(
    id: String,
    name: String,
    brand: Brand,
    codes: [String],
    kind: Kind
  ) {
    self.id = id
    self.name = name
    self.brand = brand
    self.codes = codes
    self.kind = kind
  }
}

public extension DeviceModel {
  enum Kind: Equatable {
    case bloodPressure
    case glucoseMeter
  }
}
