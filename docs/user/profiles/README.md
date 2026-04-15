# Profiles

Use this section to control which site profiles are available in the environment.

Menu items:

- [List profiles](./list-profiles.md)
- [Profile usage summary](./profile-usage-summary.md)
- [Sites using one profile](./sites-using-one-profile.md)
- [Check profiles](./check-profiles.md)
- [Turn profile on](./turn-profile-on.md)
- [Turn profile off](./turn-profile-off.md)
- [Initialize profile list](./initialize-profile-list.md)

Use `Profiles` when:

- the needed profile does not appear during site creation,
- you want to know which sites depend on a profile,
- you are validating profile definitions after updates.

This section matters before `Sites -> Create site`, not after the site is already fully running.

Typical flow:

1. `List profiles`
2. `Profile usage summary`
3. `Turn profile on` or `Turn profile off`
4. return to `Sites -> Create site`

Technical reference:

- [profile command reference](../../developer/commands/profile.md)
