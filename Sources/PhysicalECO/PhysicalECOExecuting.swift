import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PhysicalECOExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
