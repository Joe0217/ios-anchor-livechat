import XCTest

@MainActor
final class PartyCurrencyStoreTests: XCTestCase {
    func test_balanceDecode_supportsNumericStringFields() throws {
        let data = Data(#"{"diamondNum":"120","gems":"45.5","coins":8}"#.utf8)

        let balance = try PartyCurrencyBalance.decode(from: data)

        XCTAssertEqual(balance.diamonds, 120)
        XCTAssertEqual(balance.gems, Decimal(string: "45.5"))
        XCTAssertEqual(balance.coins, 8)
        XCTAssertEqual(balance.availableWholeGems, 45)
    }

    func test_exchangeDiamond_sendsValidatedAmountAndRefreshesBalance() async {
        let service = FakePartyCurrencyService(
            balances: [
                PartyCurrencyBalance(diamonds: 10, gems: 15, coins: 20),
                PartyCurrencyBalance(diamonds: 15, gems: 10, coins: 20),
            ]
        )
        let store = PartyCurrencyStore(service: service)
        await store.loadBalance()
        store.setAmount("5")

        let outcome = await store.exchange()

        XCTAssertEqual(outcome, .success(gems: 5, target: .diamond))
        XCTAssertEqual(service.exchangeCalls, [FakePartyCurrencyService.ExchangeCall(gems: 5, target: .diamond)])
        XCTAssertEqual(store.balance, PartyCurrencyBalance(diamonds: 15, gems: 10, coins: 20))
        XCTAssertEqual(store.amountText, "")
    }

    func test_exchange_rejectsFractionalRemainderAndDoesNotCallService() async {
        let service = FakePartyCurrencyService(
            balances: [PartyCurrencyBalance(diamonds: 0, gems: Decimal(string: "4.5")!, coins: 0)]
        )
        let store = PartyCurrencyStore(service: service)
        await store.loadBalance()
        store.setAmount("5")

        let outcome = await store.exchange()

        XCTAssertEqual(outcome, .validation(.insufficientGems))
        XCTAssertTrue(service.exchangeCalls.isEmpty)
        XCTAssertEqual(store.validationError, .insufficientGems)
    }

    func test_setAmount_ignoresNonAsciiNumerals() {
        let store = PartyCurrencyStore(service: FakePartyCurrencyService(balances: []))

        store.setAmount("12٣x")

        XCTAssertEqual(store.amountText, "12")
    }
}

private final class FakePartyCurrencyService: PartyCurrencyService, @unchecked Sendable {
    struct ExchangeCall: Equatable {
        let gems: Int64
        let target: PartyCurrencyTarget
    }

    private var balances: [PartyCurrencyBalance]
    private(set) var exchangeCalls: [ExchangeCall] = []

    init(balances: [PartyCurrencyBalance]) {
        self.balances = balances
    }

    func fetchBalance() async throws -> PartyCurrencyBalance {
        guard !balances.isEmpty else { return .empty }
        return balances.count == 1 ? balances[0] : balances.removeFirst()
    }

    func exchange(gems: Int64, target: PartyCurrencyTarget) async throws {
        exchangeCalls.append(ExchangeCall(gems: gems, target: target))
    }
}
