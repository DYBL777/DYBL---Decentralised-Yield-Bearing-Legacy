## Status: Early Research Prototype (Alpha)

This is a proof-of-concept implementation of the Eternal Seed primitive and Lettery flagship application.  
It successfully demonstrates the core mechanics but is **not yet production-ready** and contains known limitations.

**Critical Known Issues** (priority fixes needed before testnet):
- Weekly draws rely on ticket purchases to trigger VRF → risks skipped weeks (planned: migrate to Chainlink Automation for reliable timing)
- Eternal Seed injection takes flat % of total funds → too aggressive and doesn't yet follow the rolling/decreasing schedule in the white paper
- Yield accounting has long-term drift due to aToken compounding (standard challenge, needs shares-based or harvest tracking)
- No emergency pause/migration functions implemented yet
- LINK funding is placeholder → risk of stalled draws

**Other Known Issues**:
- Cashback claimable multiple times per year (no per-year tracking)
- Lottery match counting allows duplicate symbol credit (may change)
- Treasury seed taper not gradual
- Minor UX/gas issues (single-ticket buys, etc.)

We are openly seeking technical partners — especially Chainlink ecosystem teams, Cyfrin auditors, and Aave — to help resolve these, integrate Automation/CCIP properly, run detailed simulations, and prepare for full security audit.

Transparency is core to this project. Contributions, feedback, and simulations very welcome!

## License
**Business Source License 1.1 (BUSL-1.1)**
...
