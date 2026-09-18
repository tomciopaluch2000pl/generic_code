# IBM Storage Protect 8.1.25
## Event-Based Archive Retention Change Runbook

### Purpose

This runbook describes how to increase the retention period for archive objects that were created with an event-based archive copy group using:

```text
RETINIT=EVENT
RETVER=0
RETMIN=365
```

The required target is:

```text
RETINIT=EVENT
RETVER=0
RETMIN=30000
```

The main objective is to prevent existing archive objects from becoming eligible for expiration under the old one-year retention setting.

---

## 1. Important retention behavior

For event-based retention:

- `RETINIT=EVENT` means that the event starts the retention period controlled by `RETVER`.
- `RETVER=0` means that the event-based part of the retention expires immediately after the `ACTIVATE` event.
- `RETMIN` is the minimum number of days that the archive object must be retained from its archive/creation date.
- Before `ACTIVATE`, an event-based object remains protected and is not eligible for normal expiration.
- After `ACTIVATE`, the object can expire only when the applicable retention conditions are satisfied.

For the target configuration, the intended rule is:

```text
Object eligibility = archive date + 30000 days
```

Therefore, an object archived 800 days ago must not become eligible merely because it is older than the previous `RETMIN=365` value.

---

## 2. What IBM Support confirms

IBM Support has a document titled **Changing the retention of existing archive copies**.

IBM's publicly visible abstract states that retention of existing archive copies can be changed by modifying the `RETVER` parameter of an archive copy group. The article applies to IBM Spectrum Protect Server and is marked for all supported versions. The full article requires IBM Support authentication.

Reference:

```text
IBM Support case: TS004004861
IBM document UID: ibm16365445
```

Link:

https://www.ibm.com/support/pages/changing-retention-existing-archive-copies

### Limitation of the public IBM statement

The public abstract explicitly mentions `RETVER`; it does not explicitly confirm that changing `RETMIN` is retroactively applied to existing event-based objects that are still pending an activation event.

IBM documentation and Redbooks describe the event-based retention model, but this specific `RETMIN` scenario should be validated with one controlled test object or confirmed directly with IBM Support before sending a mass `ACTIVATE` event.

Do not make assumptions based only on the displayed expiration date or on the fact that the object is older than 365 days.

---

## 3. Preconditions and safety rules

Before making the change:

1. Identify the exact policy domain, policy set, management class, and archive copy group.
2. Confirm that the objects are archive objects, not backup objects.
3. Confirm that the objects are bound to the management class being changed.
4. Prevent or postpone automated `ACTIVATE` events while the policy change is being prepared.
5. Do not send a mass activation event until the test procedure has succeeded.
6. Do not modify the Storage Protect database directly.

If an object has already been physically deleted by inventory expiration, changing the policy cannot recover it.

---

## 4. Check the current archive copy group

Run:

```text
q copygroup <DOMAIN> ACTIVE <MGMTCLASS> type=archive f=d
```

Record at least:

```text
Policy Domain Name
Policy Set Name
Mgmt Class Name
Copy Group Type
Retention Initiation
Retain Minimum Days
Retain Version
Copy Destination
```

Expected current values:

```text
Retention Initiation: EVENT
Retain Minimum Days: 365
Retain Version: 0
```

Also verify that the command is supported on the installed server level:

```text
help update copygroup
```

If `RETMIN` is rejected by the server command parser, stop the change and raise the question with IBM Support. Do not use an undocumented database modification.

---

## 5. Update the policy safely

An active policy set should not be modified directly. Create a copy of the active policy set and change the copy.

Example:

```text
copy policyset <DOMAIN> ACTIVE RET30000
```

Update only the required parameter and preserve the event-based settings:

```text
update copygroup <DOMAIN> RET30000 <MGMTCLASS> STANDARD type=archive retmin=30000
```

Do not change these values for this use case:

```text
RETINIT=EVENT
RETVER=0
```

Validate the new policy set:

```text
validate policyset <DOMAIN> RET30000
```

If validation is successful, activate it:

```text
activate policyset <DOMAIN> RET30000
```

Verify the active values:

```text
q copygroup <DOMAIN> ACTIVE <MGMTCLASS> type=archive f=d
```

The result should show:

```text
Retention Initiation: EVENT
Retain Minimum Days: 30000
Retain Version: 0
```

If an existing inactive policy set is already used for the change, the `COPY POLICYSET` step is not required. Update that inactive policy set, validate it, and activate it.

---

## 6. Controlled test before mass activation

The safest production approach is to test one existing object first.

Select an object that:

- was archived more than 365 days ago;
- was archived less than 30000 days ago;
- is still present on the Storage Protect server;
- is not under a separate hold or special management class;
- can safely be activated for the test.

After the new policy set is active, send the `ACTIVATE` event for only that test object using the normal application/API process.

Do not use a mass event for the whole archive collection at this stage.

After activation, verify that:

- the object is still present;
- it is not treated as immediately expired because it is older than 365 days;
- the object remains protected until the new retention requirement is satisfied;
- no unexpected expiration or deletion messages appear in the activity log.

The normal `EXPIRE INVENTORY` process can be allowed to evaluate the test object after the policy change. Do not force a large expiration run merely to test the policy unless this has been agreed with the Storage Protect operations team.

If the test object remains protected, proceed with the agreed activation process for the remaining objects.

If the test object becomes eligible for expiration, stop immediately and open an IBM Support case before activating any additional objects.

---

## 7. Existing objects already activated

The situation is more sensitive if objects have already received `ACTIVATE` and are in the `STARTED` state.

IBM Support explicitly documents changing retention of existing archive copies through archive copy group retention changes, particularly `RETVER`. However, the publicly available IBM statement does not explicitly confirm the retroactive behavior of `RETMIN` for this exact event-based scenario.

For already activated objects:

1. Do not assume that changing `RETMIN` alone is sufficient.
2. Test one representative object if possible.
3. Check whether it is still present and whether a hold is active.
4. Confirm the result with IBM Support if the data is subject to compliance or regulatory retention.

Suggested IBM Support question:

```text
On IBM Storage Protect Server 8.1.25, for an existing archive object
with RETINIT=EVENT, RETVER=0 and RETMIN=365, does changing the archive
copy group to RETMIN=30000 before ACTIVATE apply retroactively, or will
ACTIVATE use the original RETMIN=365 value?
```

---

## 8. Scope of the change

Changing the archive copy group affects all existing and future archive objects that use the affected management class/policy structure.

If only a subset of data requires the longer retention, do not change the shared copy group without reviewing the impact on all nodes. IBM Support describes using a separate policy domain with a management class of the same name when retention must be changed for only one node or subset of data.

Reference:

https://www.ibm.com/support/pages/retention-modification-subset-data-management-class

---

## 9. CMOD/application-side consideration

If the activation event is generated by CMOD or another archive application, changing Storage Protect does not necessarily change retention metadata maintained by that application.

The application may still calculate or display the old one-year retention date and may still send `ACTIVATE` according to its existing process. The Storage Protect policy must therefore be corrected before activation, and the application-side retention configuration should be reviewed separately.

---

## Recommended production sequence

```text
1. Stop or postpone mass ACTIVATE events.
2. Query the current archive copy group.
3. Clone the active policy set.
4. Change RETMIN from 365 to 30000 in the clone.
5. Validate the clone.
6. Activate the corrected policy set.
7. Verify the active copy group.
8. ACTIVATE one controlled test object.
9. Confirm that the test object remains protected.
10. Proceed with the remaining events only after the test is successful.
```

### Bottom line

Do not send the production `ACTIVATE` event while the archive copy group still shows `RETMIN=365`.

Change and activate the policy first, then validate the behavior with one existing object. This avoids relying on an unverified assumption about how `RETMIN` is applied to existing event-based archive objects on IBM Storage Protect 8.1.25.

