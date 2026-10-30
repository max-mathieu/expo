// Copyright 2026-present 650 Industries. All rights reserved.

/**
 The registry of the packages that a modules provider returns in `packages`, keyed by the npm package name.
 It backs `expo.packages`, the same way `ModuleRegistry` backs `expo.modules`, and the two are independent:
 a module that is only in a package isn't in `ModuleRegistry`, and modules of different packages can have the same name.
 A module type that `ModuleRegistry` has too shares its holder, so it has one native instance and one JavaScript object.
 */
internal final class PackageRegistry {
  private weak var appContext: AppContext?

  private let packages = Mutex<[String: RegisteredPackage]>([:])

  init(appContext: AppContext) {
    self.appContext = appContext
  }

  // MARK: - Registration

  /**
   Registers the packages of the given modules provider. Register the provider in `ModuleRegistry` first,
   so the modules that it also returns from `getModuleClasses()` reuse their holders.
   */
  func register(fromProvider provider: ModulesProviderProtocol) {
    for (packageName, package) in provider.packages {
      register(package: package, named: packageName)
    }
  }

  /**
   Registers the modules and shared object classes of the package with the given name. A module whose type
   is in `ModuleRegistry` reuses that holder, and other modules get a holder that is only in the package.
   */
  func register(package: ExpoPackage, named packageName: String) {
    guard let appContext else {
      log.error("Unable to register the '\(packageName)' package, the app context is unavailable")
      return
    }
    register(sharedObjects: package.sharedObjects, inPackage: packageName)

    for moduleType in package.modules {
      if let holder = appContext.moduleRegistry.first(where: { type(of: $0.module) == moduleType }) {
        register(holder: holder, inPackage: packageName)
      } else {
        let holder = ModuleHolder(appContext: appContext, module: moduleType.init(appContext: appContext), name: nil)
        register(holder: holder, inPackage: packageName)
        holder.module.didCreate()
      }
    }
  }

  /**
   Registers the module holder in the package with the given name. A module with the same name in the package is replaced.
   */
  func register(holder: ModuleHolder, inPackage packageName: String) {
    log.info("Registering module '\(holder.name)' in package '\(packageName)'")

    packages.withLock { packages in
      packages[packageName, default: RegisteredPackage()].modules[holder.name] = holder
    }
  }

  /**
   Registers the shared object classes in the package with the given name. Their JavaScript classes are built
   on the first access, not here.
   */
  func register(sharedObjects: [SharedObject.Type], inPackage packageName: String) {
    packages.withLock { packages in
      packages[packageName, default: RegisteredPackage()].sharedObjects.append(contentsOf: sharedObjects)
    }
  }

  // MARK: - Accessing

  /**
   The names of the registered packages. The local package comes first, and the others are sorted.
   */
  var packageNames: [String] {
    let names = packages.withLock { packages in
      return Array(packages.keys)
    }
    return names.sorted { lhs, rhs in
      if (lhs == ExpoPackage.localPackageName) != (rhs == ExpoPackage.localPackageName) {
        return lhs == ExpoPackage.localPackageName
      }
      return lhs < rhs
    }
  }

  /**
   Returns whether the package with the given name is registered.
   */
  func hasPackage(named packageName: String) -> Bool {
    return packages.withLock { packages in
      return packages[packageName] != nil
    }
  }

  /**
   Returns the holders of the modules in the package with the given name, sorted by the module name.
   */
  func moduleHolders(inPackage packageName: String) -> [ModuleHolder] {
    let holders = packages.withLock { packages in
      return packages[packageName]?.modules.values.map { $0 } ?? []
    }
    return holders.sorted { $0.name < $1.name }
  }

  /**
   The holders of the modules in all packages. A holder that is in more than one package is listed for each of them.
   */
  var moduleHolders: [ModuleHolder] {
    return packages.withLock { packages in
      return packages.values.flatMap(\.modules.values)
    }
  }

  /**
   Returns the shared object classes of the package with the given name, in the order they were registered.
   */
  func sharedObjectTypes(inPackage packageName: String) -> [SharedObject.Type] {
    return packages.withLock { packages in
      return packages[packageName]?.sharedObjects ?? []
    }
  }

  /**
   Returns the shared object class with the given native type identifier that any package exports.
   */
  func sharedObjectType(for typeId: ObjectIdentifier) -> SharedObject.Type? {
    return packages.withLock { packages in
      for package in packages.values {
        if let type = package.sharedObjects.first(where: { ObjectIdentifier($0) == typeId }) {
          return type
        }
      }
      return nil
    }
  }
}

/**
 The modules and shared object classes of one package in the package registry.
 */
private struct RegisteredPackage {
  /**
   Holders of the package's modules, keyed by the module name.
   */
  var modules: [String: ModuleHolder] = [:]

  /**
   Shared object classes that the package exports next to its modules.
   */
  var sharedObjects: [SharedObject.Type] = []
}
