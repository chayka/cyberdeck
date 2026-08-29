// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Waveshare UPS HAT (E) — power_supply class driver.
 *
 * The userspace port next door (ups/ups_hat_e.py) can already read this board
 * correctly, so why a kernel module at all? Because "read it correctly" and
 * "the machine behaves like a laptop" are different problems.
 *
 * Everything that makes a laptop feel like a laptop on a battery — the battery
 * menu, the percentage in the top bar, "1:47 remaining", the low-battery
 * warning, the automatic shutdown before the pack dies, gnome-control-center's
 * Power panel — is UPower asking the kernel. UPower does not have a plugin
 * interface for "some Python script knows the answer". It enumerates
 * /sys/class/power_supply, and a device is either there or it does not exist as
 * far as the desktop is concerned. That is the whole reason this file exists:
 * the indicator could only ever *draw a picture of* a battery next to the real
 * status area, and nothing downstream of it — not GNOME, not systemd-logind,
 * not any application asking "am I on battery?" — could see the pack at all.
 *
 * So this registers two power supplies:
 *
 *   BAT0  POWER_SUPPLY_TYPE_BATTERY   the 4S pack behind the BQ4050 gauge
 *   AC0   POWER_SUPPLY_TYPE_MAINS     the barrel-jack/USB-C input via IP2368
 *
 * Both are needed. A battery alone leaves UPower guessing at whether the deck
 * is running on wall power; the MAINS device is what turns that into a fact,
 * and it is what makes the plug icon appear.
 *
 * Register semantics follow Waveshare's register manual, which is a *separate*
 * wiki page from the product page and is not reflected in their demo code:
 *
 *     https://www.waveshare.com/wiki/UPS_HAT_(E)_Register
 *
 * The board carries a BQ4050 fuel gauge and an IP2368 charger behind an MCU at
 * 0x2d — not the INA219 the product page's section heading implies, and not
 * anything the in-tree sbs-battery driver can talk to: the MCU presents its own
 * flat register map, not SBS commands.
 *
 * Two decoding bugs are inherited from ups_hat_e.py, where they are documented
 * at length. Restating them here because they are the reason this driver does
 * not simply mirror the vendor demo:
 *
 *   - Bits 5/6/7 of register 0x02 are *independent flags* (charging, fast
 *     charging, VBUS present), not a three-state enum. The vendor demo reads
 *     them as an if/elif chain and so reports "fast charging" whenever the
 *     input is merely plugged in. On this board all three read set at once.
 *     STATUS is therefore derived from measured current, not from the flags —
 *     see ups_hat_e_status().
 *   - Signed current is two's complement over 16 bits, so the correction is
 *     -0x10000, not the vendor's -0xFFFF (off by one on every negative sample).
 *
 * Copyright (c) 2026 Boris Mossounov
 */

#include <linux/bitops.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/mutex.h>
#include <linux/power_supply.h>
#include <linux/reboot.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/workqueue.h>

#define UPS_REG_ID		0x00	/* fixed 0x0a */
#define UPS_REG_CONTROL		0x01	/* fixed 0x0b on read; command on write */
#define UPS_REG_CHARGE		0x02	/* charge flags + charge stage */
#define UPS_REG_COMMS		0x03	/* BQ4050 / IP2368 link health */
#define UPS_REG_VBUS		0x10	/* 6 bytes: mV, mA, mW */
#define UPS_REG_BATTERY		0x20	/* 12 bytes: mV, mA (signed), %, mAh, min, min */
#define UPS_REG_CELLS		0x30	/* 8 bytes: cell 1-4 mV */
#define UPS_REG_SW_REVISION	0x50	/* 0x14 == v2.0 */

/*
 * Written to UPS_REG_CONTROL: the MCU cuts the 5V rail to the Pi after ~30s and
 * restores it once a charger is detected. See ups_hat_e_power_off().
 */
#define UPS_CMD_POWEROFF_RESTART_ON_CHARGE	0x55

/* Register 0x02 flag bits. Independent, not an enum — see the file comment. */
#define UPS_CHARGING		BIT(7)
#define UPS_FAST_CHARGING	BIT(6)
#define UPS_VBUS_PRESENT	BIT(5)
#define UPS_STAGE_MASK		GENMASK(2, 0)

/* Register 0x03 link-health bits. */
#define UPS_GAUGE_OK		BIT(1)		/* BQ4050 */
#define UPS_CHARGER_OK		BIT(0)		/* IP2368 */

/* The 16-bit registers use 0xffff for "no estimate available". */
#define UPS_UNKNOWN		0xffff

#define UPS_CELLS		4

/*
 * Per-cell thresholds. The pack percentage comes from the gauge, but a 4S pack
 * can read a plausible percentage while one cell is collapsing, so the critical
 * decision is made on the weakest cell rather than on state of charge.
 */
#define UPS_CELL_CRITICAL_UV	3150000
#define UPS_CELL_LOW_UV		3400000
#define UPS_CELL_OVERVOLT_UV	4250000

/*
 * Current magnitude below which the pack counts as neither charging nor
 * discharging.
 *
 * Without this the driver flaps. A pack held at the constant-voltage stage
 * settles to a few mA of taper current that crosses zero between samples, and
 * status followed it every poll: charging, full, charging, full. UPower records
 * each flip in its history and GNOME redraws the icon, which is a lot of motion
 * to describe a battery that is sitting still. 30 mA is comfortably above the
 * taper and three orders of magnitude below this deck's ~700 mA draw, so it
 * cannot mask a pack that is genuinely being discharged.
 */
#define UPS_CURRENT_DEADBAND_UA	30000

enum ups_hat_e_stage {
	UPS_STAGE_STANDBY		= 0,
	UPS_STAGE_TRICKLE		= 1,
	UPS_STAGE_CONSTANT_CURRENT	= 2,
	UPS_STAGE_CONSTANT_VOLTAGE	= 3,
	UPS_STAGE_PENDING		= 4,
	UPS_STAGE_FULL			= 5,
	UPS_STAGE_TIMEOUT		= 6,
	/* 7 is not defined by the register manual. */
};

static const char * const ups_hat_e_stage_names[] = {
	"standby", "trickle", "constant current", "constant voltage",
	"pending", "full", "timeout", "unknown",
};

/* One consistent sample of the whole board. */
struct ups_hat_e_sample {
	bool	charging_flag;
	bool	fast_charging_flag;
	bool	vbus_present;
	u8	stage;

	bool	gauge_ok;
	bool	charger_ok;

	int	vbus_uv;
	int	vbus_ua;
	int	vbus_uw;

	int	battery_uv;
	int	battery_ua;	/* positive = into the pack */
	int	percent;
	int	charge_now_uah;
	int	secs_to_empty;	/* < 0 when the gauge has no estimate */
	int	secs_to_full;

	int	cell_uv[UPS_CELLS];
};

struct ups_hat_e {
	struct i2c_client	*client;
	struct power_supply	*battery;
	struct power_supply	*mains;
	struct delayed_work	poll;

	/* Guards @sample and @valid against the poll worker vs. sysfs readers. */
	struct mutex		lock;
	struct ups_hat_e_sample	sample;
	bool			valid;
	unsigned int		fail_count;

	/* Last published values, used to decide whether to wake up UPower. */
	int			last_status;
	int			last_percent;
	bool			last_online;

	/*
	 * Full-charge capacity, learned rather than read: the MCU exposes
	 * remaining mAh but not the gauge's FullChargeCapacity register, so it
	 * is back-computed from remaining/percent. Recomputed only when the
	 * reported percentage changes, otherwise integer-percent quantisation
	 * makes the value jitter by ~50 mAh between polls.
	 */
	int			charge_full_uah;
	int			charge_full_at_percent;
};

static unsigned int poll_interval = 5;
module_param(poll_interval, uint, 0644);
MODULE_PARM_DESC(poll_interval, "seconds between I2C samples (default 5)");

static unsigned int design_capacity_mah;
module_param(design_capacity_mah, uint, 0644);
MODULE_PARM_DESC(design_capacity_mah,
		 "design capacity of the fitted cells in mAh; 0 (default) reports it as unknown, since the HAT ships without cells and the MCU does not expose a design capacity");

static bool poweroff_cuts_power;
module_param(poweroff_cuts_power, bool, 0644);
MODULE_PARM_DESC(poweroff_cuts_power,
		 "on shutdown, tell the HAT to cut the rail and restart when a charger is attached (default off; see the README before enabling)");

/* ---------------------------------------------------------------- I2C reads */

static int ups_hat_e_u16(const u8 *buf, int i)
{
	return buf[i] | buf[i + 1] << 8;
}

static int ups_hat_e_s16(const u8 *buf, int i)
{
	int v = ups_hat_e_u16(buf, i);

	/* Two's complement over 16 bits: -0x10000, not the vendor's -0xffff. */
	return v > 0x7fff ? v - 0x10000 : v;
}

/* Minutes-to-empty/full, or a negative value when the gauge has no estimate. */
static int ups_hat_e_minutes(const u8 *buf, int i)
{
	int v = ups_hat_e_u16(buf, i);

	return v == UPS_UNKNOWN ? -1 : v * 60;
}

static int ups_hat_e_read_block(struct ups_hat_e *ups, u8 reg, u8 len, u8 *buf)
{
	int ret = i2c_smbus_read_i2c_block_data(ups->client, reg, len, buf);

	if (ret < 0)
		return ret;
	if (ret != len)
		return -EIO;
	return 0;
}

static int ups_hat_e_sample_board(struct ups_hat_e *ups,
				  struct ups_hat_e_sample *s)
{
	u8 charge[2], vbus[6], battery[12], cells[8];
	int ret, i;

	/* 0x02 and 0x03 are adjacent, so one block read covers both. */
	ret = ups_hat_e_read_block(ups, UPS_REG_CHARGE, sizeof(charge), charge);
	if (ret)
		return ret;
	ret = ups_hat_e_read_block(ups, UPS_REG_VBUS, sizeof(vbus), vbus);
	if (ret)
		return ret;
	ret = ups_hat_e_read_block(ups, UPS_REG_BATTERY, sizeof(battery), battery);
	if (ret)
		return ret;
	ret = ups_hat_e_read_block(ups, UPS_REG_CELLS, sizeof(cells), cells);
	if (ret)
		return ret;

	s->charging_flag	= charge[0] & UPS_CHARGING;
	s->fast_charging_flag	= charge[0] & UPS_FAST_CHARGING;
	s->vbus_present		= charge[0] & UPS_VBUS_PRESENT;
	s->stage		= charge[0] & UPS_STAGE_MASK;

	s->gauge_ok		= charge[1] & UPS_GAUGE_OK;
	s->charger_ok		= charge[1] & UPS_CHARGER_OK;

	s->vbus_uv		= ups_hat_e_u16(vbus, 0) * 1000;
	s->vbus_ua		= ups_hat_e_u16(vbus, 2) * 1000;
	s->vbus_uw		= ups_hat_e_u16(vbus, 4) * 1000;

	s->battery_uv		= ups_hat_e_u16(battery, 0) * 1000;
	s->battery_ua		= ups_hat_e_s16(battery, 2) * 1000;
	s->percent		= clamp(ups_hat_e_u16(battery, 4), 0, 100);
	s->charge_now_uah	= ups_hat_e_u16(battery, 6) * 1000;
	s->secs_to_empty	= ups_hat_e_minutes(battery, 8);
	s->secs_to_full		= ups_hat_e_minutes(battery, 10);

	for (i = 0; i < UPS_CELLS; i++)
		s->cell_uv[i] = ups_hat_e_u16(cells, i * 2) * 1000;

	return 0;
}

/* ------------------------------------------------------- derived quantities */

static int ups_hat_e_min_cell_uv(const struct ups_hat_e_sample *s)
{
	int i, min = s->cell_uv[0];

	for (i = 1; i < UPS_CELLS; i++)
		min = min_t(int, min, s->cell_uv[i]);
	return min;
}

static int ups_hat_e_max_cell_uv(const struct ups_hat_e_sample *s)
{
	int i, max = s->cell_uv[0];

	for (i = 1; i < UPS_CELLS; i++)
		max = max_t(int, max, s->cell_uv[i]);
	return max;
}

/*
 * STATUS from measured current rather than from the flag bits.
 *
 * This is the whole point of the port. The flags stay set while VBUS is present
 * even after the charger has stopped delivering, and the MCU keeps reporting
 * stage=FULL once a charge terminates. Trusting either would make the desktop
 * show a full, charging battery while the pack quietly runs the deck down —
 * which is exactly the state this machine sits in when the charger has
 * terminated and is not carrying the load. Current is the only signal that
 * says which way the energy is actually moving.
 */
static int ups_hat_e_status(const struct ups_hat_e_sample *s)
{
	if (s->battery_ua > UPS_CURRENT_DEADBAND_UA)
		return POWER_SUPPLY_STATUS_CHARGING;
	if (s->battery_ua < -UPS_CURRENT_DEADBAND_UA)
		return POWER_SUPPLY_STATUS_DISCHARGING;

	/*
	 * Inside the deadband the pack is idle, and only here is the stage field
	 * worth consulting — the case it gets wrong is a stage of FULL while the
	 * pack quietly runs the deck down, and that draw is far outside the
	 * deadband, so it has already been caught above.
	 */
	if (s->stage == UPS_STAGE_FULL || s->percent >= 100)
		return POWER_SUPPLY_STATUS_FULL;

	/*
	 * Idle, not full, input attached: the charger has stalled, or is in a
	 * pending or timeout stage. NOT_CHARGING says that without claiming to
	 * know which.
	 */
	return s->vbus_present ? POWER_SUPPLY_STATUS_NOT_CHARGING
			       : POWER_SUPPLY_STATUS_UNKNOWN;
}

static int ups_hat_e_charge_type(const struct ups_hat_e_sample *s)
{
	if (s->battery_ua <= UPS_CURRENT_DEADBAND_UA)
		return POWER_SUPPLY_CHARGE_TYPE_NONE;
	switch (s->stage) {
	case UPS_STAGE_TRICKLE:
		return POWER_SUPPLY_CHARGE_TYPE_TRICKLE;
	case UPS_STAGE_CONSTANT_CURRENT:
	case UPS_STAGE_CONSTANT_VOLTAGE:
		return s->fast_charging_flag ? POWER_SUPPLY_CHARGE_TYPE_FAST
					     : POWER_SUPPLY_CHARGE_TYPE_STANDARD;
	default:
		return POWER_SUPPLY_CHARGE_TYPE_STANDARD;
	}
}

static int ups_hat_e_health(const struct ups_hat_e_sample *s)
{
	if (!s->gauge_ok || !s->charger_ok)
		return POWER_SUPPLY_HEALTH_UNSPEC_FAILURE;
	if (ups_hat_e_max_cell_uv(s) > UPS_CELL_OVERVOLT_UV)
		return POWER_SUPPLY_HEALTH_OVERVOLTAGE;
	if (ups_hat_e_min_cell_uv(s) < UPS_CELL_CRITICAL_UV)
		return POWER_SUPPLY_HEALTH_DEAD;
	return POWER_SUPPLY_HEALTH_GOOD;
}

/*
 * CAPACITY_LEVEL is what UPower escalates on, so the weakest cell gets a vote
 * alongside state of charge: a 4S pack can report a comfortable percentage
 * while one cell is already below the point where the MCU will cut out.
 */
static int ups_hat_e_capacity_level(const struct ups_hat_e_sample *s)
{
	int min_uv = ups_hat_e_min_cell_uv(s);

	if (s->battery_ua <= 0 && min_uv < UPS_CELL_CRITICAL_UV)
		return POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
	/*
	 * Not gated on stage == FULL: the gauge reports 100% while the charger is
	 * still in constant voltage, and reporting HIGH at a hundred percent
	 * reads as a bug to anyone looking at it.
	 */
	if (s->percent >= 100)
		return POWER_SUPPLY_CAPACITY_LEVEL_FULL;
	if (s->percent > 75)
		return POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
	if (s->percent > 20)
		return POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
	if (s->percent > 5 && min_uv > UPS_CELL_LOW_UV)
		return POWER_SUPPLY_CAPACITY_LEVEL_LOW;
	return POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
}

/* ------------------------------------------------------------- poll worker */

static void ups_hat_e_poll(struct work_struct *work)
{
	struct ups_hat_e *ups = container_of(to_delayed_work(work),
					     struct ups_hat_e, poll);
	struct ups_hat_e_sample s;
	bool battery_changed, mains_changed;
	int status, ret;

	ret = ups_hat_e_sample_board(ups, &s);
	if (ret) {
		/*
		 * Transient I2C errors happen on a HAT header. Keep serving the
		 * last good sample rather than making the battery blink out of
		 * existence in the desktop, but say so once so the cause is
		 * findable in the journal if it becomes persistent.
		 */
		if (ups->fail_count++ == 0)
			dev_warn(&ups->client->dev,
				 "I2C read failed (%d); serving last known values\n",
				 ret);
		goto out;
	}

	if (ups->fail_count) {
		dev_info(&ups->client->dev, "I2C recovered after %u failed polls\n",
			 ups->fail_count);
		ups->fail_count = 0;
	}

	status = ups_hat_e_status(&s);

	mutex_lock(&ups->lock);

	/*
	 * Learn full-charge capacity from remaining/percent. Only when the
	 * percentage actually moves, and never at very low charge where the
	 * division amplifies a one-percent quantisation error into hundreds of
	 * mAh.
	 */
	if (s.percent >= 10 && s.percent != ups->charge_full_at_percent) {
		ups->charge_full_uah = s.charge_now_uah * 100 / s.percent;
		ups->charge_full_at_percent = s.percent;
	}

	battery_changed = !ups->valid ||
			  status != ups->last_status ||
			  s.percent != ups->last_percent;
	mains_changed = !ups->valid || s.vbus_present != ups->last_online;

	ups->sample = s;
	ups->valid = true;
	ups->last_status = status;
	ups->last_percent = s.percent;
	ups->last_online = s.vbus_present;

	mutex_unlock(&ups->lock);

	/*
	 * Only wake UPower when something it displays has moved. Voltage and
	 * current jitter on every sample; firing power_supply_changed() at 0.2 Hz
	 * forever would keep the desktop's power stack busy for no visible gain.
	 */
	if (battery_changed)
		power_supply_changed(ups->battery);
	if (mains_changed)
		power_supply_changed(ups->mains);

out:
	schedule_delayed_work(&ups->poll, secs_to_jiffies(poll_interval ?: 1));
}

/* ------------------------------------------------------ power_supply: BAT0 */

static const enum power_supply_property ups_hat_e_battery_props[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_CHARGE_TYPE,
	POWER_SUPPLY_PROP_HEALTH,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_CAPACITY_LEVEL,
	POWER_SUPPLY_PROP_CHARGE_NOW,
	POWER_SUPPLY_PROP_CHARGE_FULL,
	POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW,
	POWER_SUPPLY_PROP_TIME_TO_FULL_NOW,
	POWER_SUPPLY_PROP_SCOPE,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static int ups_hat_e_battery_get(struct power_supply *psy,
				 enum power_supply_property psp,
				 union power_supply_propval *val)
{
	struct ups_hat_e *ups = power_supply_get_drvdata(psy);
	const struct ups_hat_e_sample *s = &ups->sample;
	int ret = 0;

	/*
	 * Static properties are answered without the lock so that they still
	 * work before the first successful poll — UPower reads model/manufacturer
	 * during enumeration and a device that fails those looks broken.
	 */
	switch (psp) {
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		return 0;
	case POWER_SUPPLY_PROP_SCOPE:
		/*
		 * Without SCOPE_SYSTEM, UPower files this under peripherals —
		 * the same bucket as the mouse battery already on this deck —
		 * and GNOME never treats it as the machine's own power source.
		 */
		val->intval = POWER_SUPPLY_SCOPE_SYSTEM;
		return 0;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "UPS HAT (E)";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Waveshare";
		return 0;
	case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
		if (!design_capacity_mah)
			return -ENODATA;
		val->intval = design_capacity_mah * 1000;
		return 0;
	default:
		break;
	}

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = ups_hat_e_status(s);
		break;
	case POWER_SUPPLY_PROP_CHARGE_TYPE:
		val->intval = ups_hat_e_charge_type(s);
		break;
	case POWER_SUPPLY_PROP_HEALTH:
		val->intval = ups_hat_e_health(s);
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		/*
		 * The pack is soldered to nothing — it is four cells in a cage —
		 * so "present" means the gauge is answering and reports a
		 * plausible stack voltage, not a detection pin.
		 */
		val->intval = s->gauge_ok && s->battery_uv > 0;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		val->intval = s->battery_uv;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		val->intval = s->battery_ua;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = s->percent;
		break;
	case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
		val->intval = ups_hat_e_capacity_level(s);
		break;
	case POWER_SUPPLY_PROP_CHARGE_NOW:
		val->intval = s->charge_now_uah;
		break;
	case POWER_SUPPLY_PROP_CHARGE_FULL:
		if (!ups->charge_full_uah)
			return -ENODATA;
		val->intval = ups->charge_full_uah;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_NOW:
		if (s->secs_to_empty < 0)
			return -ENODATA;
		val->intval = s->secs_to_empty;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW:
		if (s->secs_to_full < 0)
			return -ENODATA;
		val->intval = s->secs_to_full;
		break;
	default:
		ret = -EINVAL;
		break;
	}

	return ret;
}

/* -------------------------------------------------------- power_supply: AC0 */

static const enum power_supply_property ups_hat_e_mains_props[] = {
	POWER_SUPPLY_PROP_ONLINE,
	POWER_SUPPLY_PROP_VOLTAGE_NOW,
	POWER_SUPPLY_PROP_CURRENT_NOW,
	POWER_SUPPLY_PROP_POWER_NOW,
	POWER_SUPPLY_PROP_MODEL_NAME,
	POWER_SUPPLY_PROP_MANUFACTURER,
};

static int ups_hat_e_mains_get(struct power_supply *psy,
			       enum power_supply_property psp,
			       union power_supply_propval *val)
{
	struct ups_hat_e *ups = power_supply_get_drvdata(psy);
	const struct ups_hat_e_sample *s = &ups->sample;

	switch (psp) {
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "UPS HAT (E) input";
		return 0;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Waveshare";
		return 0;
	default:
		break;
	}

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	switch (psp) {
	case POWER_SUPPLY_PROP_ONLINE:
		/*
		 * VBUS present, not "current is flowing". A charger that has
		 * terminated still counts as being plugged in; conflating the
		 * two would make the plug icon flicker every time the charge
		 * cycle completes.
		 */
		val->intval = s->vbus_present;
		break;
	case POWER_SUPPLY_PROP_VOLTAGE_NOW:
		val->intval = s->vbus_uv;
		break;
	case POWER_SUPPLY_PROP_CURRENT_NOW:
		val->intval = s->vbus_ua;
		break;
	case POWER_SUPPLY_PROP_POWER_NOW:
		/*
		 * The MCU measures input power itself, so report its figure
		 * rather than multiplying the other two properties — they are
		 * sampled together but rounded to mV and mA on the way out.
		 */
		val->intval = s->vbus_uw;
		break;
	default:
		return -EINVAL;
	}

	return 0;
}

/* --------------------------------------------------- board-specific sysfs */

/*
 * Everything the power_supply class has no property for. Per-cell voltages
 * matter on a 4S pack because a single collapsing cell is invisible in the
 * aggregate percentage, and the charge stage is what distinguishes "charger
 * finished" from "charger gave up" — the two look identical from outside.
 */

static struct ups_hat_e *ups_hat_e_from_dev(struct device *dev)
{
	struct power_supply *psy = dev_get_drvdata(dev);

	return power_supply_get_drvdata(psy);
}

static ssize_t cell_voltages_show(struct device *dev,
				  struct device_attribute *attr, char *buf)
{
	struct ups_hat_e *ups = ups_hat_e_from_dev(dev);

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	return sysfs_emit(buf, "%d %d %d %d\n",
			  ups->sample.cell_uv[0], ups->sample.cell_uv[1],
			  ups->sample.cell_uv[2], ups->sample.cell_uv[3]);
}
static DEVICE_ATTR_RO(cell_voltages);

static ssize_t charge_stage_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct ups_hat_e *ups = ups_hat_e_from_dev(dev);

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	return sysfs_emit(buf, "%s\n", ups_hat_e_stage_names[ups->sample.stage]);
}
static DEVICE_ATTR_RO(charge_stage);

static ssize_t charge_flags_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct ups_hat_e *ups = ups_hat_e_from_dev(dev);

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	return sysfs_emit(buf, "charging=%d fast_charging=%d vbus_present=%d\n",
			  ups->sample.charging_flag,
			  ups->sample.fast_charging_flag,
			  ups->sample.vbus_present);
}
static DEVICE_ATTR_RO(charge_flags);

static ssize_t link_status_show(struct device *dev,
				struct device_attribute *attr, char *buf)
{
	struct ups_hat_e *ups = ups_hat_e_from_dev(dev);

	guard(mutex)(&ups->lock);

	if (!ups->valid)
		return -EAGAIN;

	return sysfs_emit(buf, "gauge=%s charger=%s\n",
			  ups->sample.gauge_ok ? "ok" : "fault",
			  ups->sample.charger_ok ? "ok" : "fault");
}
static DEVICE_ATTR_RO(link_status);

static struct attribute *ups_hat_e_attrs[] = {
	&dev_attr_cell_voltages.attr,
	&dev_attr_charge_stage.attr,
	&dev_attr_charge_flags.attr,
	&dev_attr_link_status.attr,
	NULL,
};

static const struct attribute_group ups_hat_e_attr_group = {
	.attrs = ups_hat_e_attrs,
};

static const struct attribute_group *ups_hat_e_attr_groups[] = {
	&ups_hat_e_attr_group,
	NULL,
};

/* ---------------------------------------------------------------- shutdown */

/*
 * Opt-in, and off by default on purpose.
 *
 * 0x55 tells the MCU to drop the rail ~30s after the Pi halts and to bring it
 * back when a charger is attached. On battery that is exactly what you want and
 * is the one thing a bare Pi cannot do: `poweroff` on a Pi leaves the board
 * drawing from the pack indefinitely, so an overnight "shutdown" can still
 * flatten the cells.
 *
 * The catch is the other half of the same command. Shut down while the charger
 * is *already* attached and the restart condition is satisfied the moment the
 * rail drops, so the deck powers straight back up — a shutdown that reboots.
 * Whether that happens depends on how the MCU edge-detects the charger, which
 * the register manual does not specify, so this stays behind a module parameter
 * until it has been tried on the bench both ways.
 */
static int ups_hat_e_power_off(struct sys_off_data *data)
{
	struct ups_hat_e *ups = data->cb_data;
	int ret;

	ret = i2c_smbus_write_byte_data(ups->client, UPS_REG_CONTROL,
					UPS_CMD_POWEROFF_RESTART_ON_CHARGE);
	if (ret)
		dev_err(&ups->client->dev,
			"could not arm rail cut-off (%d); the HAT will keep powering the deck\n",
			ret);
	else
		dev_info(&ups->client->dev,
			 "rail cut-off armed; power returns when a charger is attached\n");

	/* Advisory only — the SoC still performs its own power-off. */
	return NOTIFY_DONE;
}

/* ------------------------------------------------------------------- probe */

static int ups_hat_e_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct power_supply_config battery_cfg = {};
	struct power_supply_config mains_cfg = {};
	struct power_supply_desc *battery_desc, *mains_desc;
	static char * const supplied_to[] = { "BAT0" };
	struct ups_hat_e *ups;
	int ret, revision;

	if (!i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_READ_I2C_BLOCK |
				     I2C_FUNC_SMBUS_WRITE_BYTE_DATA))
		return dev_err_probe(dev, -EOPNOTSUPP,
				     "adapter lacks SMBus block reads\n");

	ups = devm_kzalloc(dev, sizeof(*ups), GFP_KERNEL);
	if (!ups)
		return -ENOMEM;

	ups->client = client;
	i2c_set_clientdata(client, ups);

	ret = devm_mutex_init(dev, &ups->lock);
	if (ret)
		return ret;

	/*
	 * Confirm there is really a UPS HAT here before claiming BAT0. The
	 * address is not self-identifying and a wrong overlay or a stale
	 * new_device write would otherwise register a battery backed by
	 * whatever else answers at 0x2d.
	 */
	ret = i2c_smbus_read_byte_data(client, UPS_REG_ID);
	if (ret < 0)
		return dev_err_probe(dev, ret, "no response at 0x%02x\n",
				     client->addr);
	if (ret != 0x0a)
		return dev_err_probe(dev, -ENODEV,
				     "ID register reads 0x%02x, expected 0x0a; this is not a UPS HAT (E)\n",
				     ret);

	revision = i2c_smbus_read_byte_data(client, UPS_REG_SW_REVISION);
	if (revision >= 0)
		dev_info(dev, "UPS HAT (E) firmware v%d.%d\n",
			 revision / 10, revision % 10);

	/*
	 * Take the first sample *before* registering anything. UPower reads the
	 * whole property set the instant the uevent for a new power supply lands,
	 * and a device that answers -EAGAIN to all of it during enumeration can
	 * be written off as unusable and never retried. By the time BAT0 exists
	 * it should already have real numbers behind it.
	 */
	ret = ups_hat_e_sample_board(ups, &ups->sample);
	if (ret)
		return dev_err_probe(dev, ret, "initial read failed\n");

	ups->valid = true;
	ups->last_status = ups_hat_e_status(&ups->sample);
	ups->last_percent = ups->sample.percent;
	ups->last_online = ups->sample.vbus_present;
	if (ups->sample.percent >= 10) {
		ups->charge_full_uah =
			ups->sample.charge_now_uah * 100 / ups->sample.percent;
		ups->charge_full_at_percent = ups->sample.percent;
	}

	battery_desc = devm_kzalloc(dev, sizeof(*battery_desc), GFP_KERNEL);
	mains_desc = devm_kzalloc(dev, sizeof(*mains_desc), GFP_KERNEL);
	if (!battery_desc || !mains_desc)
		return -ENOMEM;

	/*
	 * BAT0/AC0 rather than something board-specific: every piece of advice
	 * about Linux power management, and a fair amount of software, assumes
	 * those names. Nothing else on this machine registers a system battery,
	 * so there is no collision to avoid — and the point of the exercise is
	 * for the deck to be indistinguishable from a laptop.
	 */
	battery_desc->name = "BAT0";
	battery_desc->type = POWER_SUPPLY_TYPE_BATTERY;
	battery_desc->properties = ups_hat_e_battery_props;
	battery_desc->num_properties = ARRAY_SIZE(ups_hat_e_battery_props);
	battery_desc->get_property = ups_hat_e_battery_get;
	/* The MCU exposes no pack temperature, so there is no zone to create. */
	battery_desc->no_thermal = true;

	mains_desc->name = "AC0";
	mains_desc->type = POWER_SUPPLY_TYPE_MAINS;
	mains_desc->properties = ups_hat_e_mains_props;
	mains_desc->num_properties = ARRAY_SIZE(ups_hat_e_mains_props);
	mains_desc->get_property = ups_hat_e_mains_get;

	battery_cfg.drv_data = ups;
	battery_cfg.fwnode = dev_fwnode(dev);
	battery_cfg.attr_grp = ups_hat_e_attr_groups;

	mains_cfg.drv_data = ups;
	mains_cfg.fwnode = dev_fwnode(dev);
	/* Lets a change on the input propagate to the battery's listeners. */
	mains_cfg.supplied_to = (char **)supplied_to;
	mains_cfg.num_supplicants = ARRAY_SIZE(supplied_to);

	ups->battery = devm_power_supply_register(dev, battery_desc, &battery_cfg);
	if (IS_ERR(ups->battery))
		return dev_err_probe(dev, PTR_ERR(ups->battery),
				     "failed to register BAT0\n");

	ups->mains = devm_power_supply_register(dev, mains_desc, &mains_cfg);
	if (IS_ERR(ups->mains))
		return dev_err_probe(dev, PTR_ERR(ups->mains),
				     "failed to register AC0\n");

	if (poweroff_cuts_power) {
		/*
		 * PREPARE, not POWER_OFF: the handler must run while the I2C
		 * controller is still alive and before anything takes over the
		 * final power-down path.
		 */
		ret = devm_register_sys_off_handler(dev,
						    SYS_OFF_MODE_POWER_OFF_PREPARE,
						    SYS_OFF_PRIO_DEFAULT,
						    ups_hat_e_power_off, ups);
		if (ret)
			return dev_err_probe(dev, ret,
					     "failed to register power-off handler\n");
	}

	INIT_DELAYED_WORK(&ups->poll, ups_hat_e_poll);
	schedule_delayed_work(&ups->poll, secs_to_jiffies(poll_interval ?: 1));

	dev_info(dev, "BAT0 %d%%, %d.%02dV, AC0 %s\n",
		 ups->sample.percent,
		 ups->sample.battery_uv / 1000000,
		 (ups->sample.battery_uv / 10000) % 100,
		 ups->sample.vbus_present ? "online" : "offline");
	return 0;
}

static void ups_hat_e_remove(struct i2c_client *client)
{
	struct ups_hat_e *ups = i2c_get_clientdata(client);

	/*
	 * disable_, not cancel_: the worker re-arms itself on every run, and
	 * cancel_delayed_work_sync() can lose that race — it cancels the pending
	 * timer, then the already-running instance queues a fresh one on its way
	 * out. The work would then fire against an ups freed by devm cleanup.
	 * disable_delayed_work_sync() blocks further queueing before waiting.
	 */
	disable_delayed_work_sync(&ups->poll);
}

static const struct i2c_device_id ups_hat_e_id[] = {
	{ "ups-hat-e" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ups_hat_e_id);

static const struct of_device_id ups_hat_e_of_match[] = {
	{ .compatible = "waveshare,ups-hat-e" },
	{ }
};
MODULE_DEVICE_TABLE(of, ups_hat_e_of_match);

static struct i2c_driver ups_hat_e_driver = {
	.driver = {
		.name = "ups-hat-e",
		.of_match_table = ups_hat_e_of_match,
	},
	.probe = ups_hat_e_probe,
	.remove = ups_hat_e_remove,
	.id_table = ups_hat_e_id,
};
module_i2c_driver(ups_hat_e_driver);

MODULE_AUTHOR("Boris Mossounov");
MODULE_DESCRIPTION("Waveshare UPS HAT (E) power_supply driver");
MODULE_LICENSE("GPL");
