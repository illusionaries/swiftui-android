// CoreData — platform shim for the Android port.
//
// CoreData is an ObjC framework (`CoreData.framework/Headers/*.h`) with a 1,299-line Swift
// overlay. It cannot be retargeted (no Clang importer on Android) and the port's engine does
// not use it. The retargeted SwiftUI interface references five CoreData names from its
// managed-object / fetch-request views (`NSManagedObject`, `NSManagedObjectContext`,
// `NSEntityDescription`, `NSFetchRequest<ResultType>`, `NSFetchRequestResult`), declared
// below from Apple's headers.
//
// Declaration-only: every body traps. If the Android runtime ever needs persistence it will
// use SQLite/`android.database` in the engine target.
public import Foundation

public protocol NSFetchRequestResult: AnyObject {
}

open class NSManagedObject: NSObject, NSFetchRequestResult {
    public override init() { fatalError() }
}

open class NSManagedObjectContext: NSObject {
    public override init() { fatalError() }
}

open class NSEntityDescription: NSObject {
    public override init() { fatalError() }
}

open class NSFetchRequest<ResultType>: NSObject where ResultType: NSFetchRequestResult {
    public override init() { fatalError() }

    public var predicate: NSPredicate? { fatalError() }

    public var sortDescriptors: [NSSortDescriptor]? { fatalError() }
}
