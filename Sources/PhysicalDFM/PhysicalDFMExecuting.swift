import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PhysicalDFMExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
