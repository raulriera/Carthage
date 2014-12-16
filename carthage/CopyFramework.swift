//
//  CopyFramework.swift
//  Carthage
//
//  Created by Robert Böhnke on 10/12/14.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

import CarthageKit
import Commandant
import Foundation
import LlamaKit
import ReactiveCocoa


public struct CopyFrameworkCommand: CommandType {
	public let verb = "copy-framework"
	public let function = "Copies the framework, striping symbols as necesssary."

	public func run(mode: CommandMode) -> Result<()> {
		return ColdSignal.fromResult(CopyFrameworkOptions.evaluate(mode))
			.map { self.copyFrameworkWithOptions($0) }
			.merge(identity)
			.wait()
	}

	public func copyFrameworkWithOptions(options: CopyFrameworkOptions) -> ColdSignal<()> {
		let source = iOSDependenciesPath().map({ $0.URLByAppendingPathComponent(options.framework, isDirectory: true) })
		let target = frameworksFolder().map({ $0.URLByAppendingPathComponent(options.framework, isDirectory: true) })

		return ColdSignal.fromResult(source)
			.combineLatestWith(.fromResult(target))
			.map { (source, target) -> ColdSignal<()> in
				let stripArchitectures = architecturesInFramework(target)
					.combineLatestWith(.fromResult(validArchitectures()))
					.map { (existingArchitectures, validArchitectures) -> ColdSignal<()> in
						let tasks = existingArchitectures.filter {
								!contains(validArchitectures, $0)
							}
							.map { architecture -> ColdSignal<()> in
								return stripArchitecture(target, architecture)
							}

						return concat(tasks)
					}
					.merge(identity)

				let codeSign = ColdSignal<()>.lazy {
					if !codeSigningAllowed() { return .empty() }

					return ColdSignal.fromResult(getEnvironmentVariable("EXPANDED_CODE_SIGN_IDENTITY"))
						.map({ codesign(target, $0) })
						.merge(identity)
				}

				return copyFramework(source, target)
					.concat(stripArchitectures)
					.concat(codeSign)
					.then(.empty())
			}
			.merge(identity)
	}
}

public struct CopyFrameworkOptions: OptionsType {
	public let framework: String

	public static func create(framework: String) -> CopyFrameworkOptions {
		return self(framework: framework)
	}

	public static func evaluate(m: CommandMode) -> Result<CopyFrameworkOptions> {
		return create
			<*> m <| Option(usage: "The framework to copy, strip and sign")
	}
}

private func concat<T>(signals: [ColdSignal<T>]) -> ColdSignal<T> {
	return reduce(signals, ColdSignal<T>.empty(), { $0.concat($1) })
}

private func codeSigningAllowed() -> Bool {
	return getEnvironmentVariable("CODE_SIGNING_ALLOWED").map({ $0 == "YES" }).value() ?? false
}

private func frameworksFolder() -> Result<NSURL> {
	let configurationBuildDir = getEnvironmentVariable("CONFIGURATION_BUILD_DIR")
	let frameworksFolderPath = getEnvironmentVariable("FRAMEWORKS_FOLDER_PATH")

	if !configurationBuildDir.isSuccess() || !frameworksFolderPath.isSuccess() {
		return failure(configurationBuildDir.error() ?? frameworksFolderPath.error()!)
	}

	let URL = NSURL(fileURLWithPath: configurationBuildDir.value()!, isDirectory: true)!.URLByAppendingPathComponent(frameworksFolderPath.value()!, isDirectory: true)

	return success(URL)
}

private func iOSDependenciesPath() -> Result<NSURL> {
	return getEnvironmentVariable("SRCROOT").map {
		NSURL(fileURLWithPath: $0, isDirectory: true)!.URLByAppendingPathComponent("\(CarthageBinariesFolderName)/iOS/", isDirectory: true)
	}
}

private func validArchitectures() -> Result<[String]> {
	return getEnvironmentVariable("VALID_ARCHS").map({ return split($0, { $0 == " " }) })
}

private func getEnvironmentVariable(variable: String) -> Result<String> {
	let environment = NSProcessInfo.processInfo().environment

	if let value = environment[variable] as String? {
		return success(value)
	} else {
		return failure(CarthageError.MissingEnvironmentVariableError(variable: variable).error)
	}
}