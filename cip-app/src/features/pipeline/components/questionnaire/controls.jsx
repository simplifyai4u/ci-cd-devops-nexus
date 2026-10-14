import { memo, useState } from 'react';
import { ChevronDown } from 'lucide-react';
import { cn } from '@/core/lib/utils';
import { Input } from '@/shared/ui/input';
import { Switch } from '@/shared/ui/switch';

/** Answers are compared the way the server stores them: arrays as sets, everything else by value. */
export const sameAnswer = (a, b) =>
    Array.isArray(a) || Array.isArray(b)
        ? [...(a || [])].sort().join('|') === [...(b || [])].sort().join('|')
        : a === b;

const RecommendedTag = () => (
    <span className="bg-primary/15 text-primary ml-1.5 rounded px-1 text-[10px] font-medium">
        Recommended
    </span>
);

const RecordedTag = () => (
    <span className="bg-muted text-muted-foreground ml-1.5 rounded px-1 text-[10px]">
        recorded only
    </span>
);

const Option = memo(function Option({
    active,
    disabled,
    recommended,
    later,
    segmented,
    onSelect,
    children,
    ...rest
}) {
    return (
        <button
            type="button"
            disabled={disabled}
            onClick={onSelect}
            className={cn(
                'focus-visible:ring-ring/50 outline-none focus-visible:ring-[3px] disabled:cursor-not-allowed disabled:opacity-50',
                segmented
                    ? 'rounded-md px-3 py-1.5 text-sm'
                    : 'rounded-full border px-3 py-1 text-xs',
                active
                    ? segmented
                        ? 'bg-background text-foreground font-medium shadow-sm'
                        : 'border-primary bg-primary/10 text-primary'
                    : cn('text-muted-foreground', !disabled && 'hover:bg-muted'),
                later && !segmented && 'border-dashed'
            )}
            {...rest}
        >
            {children}
            {recommended && <RecommendedTag />}
            {later && <RecordedTag />}
        </button>
    );
});

/**
 * One `single` / `multi` question as accessible choices.
 * single → radiogroup (arrow keys move the selection), multi → toggle buttons (aria-pressed).
 * `disabled` lists option values that cannot be picked right now; they are shown as off.
 */
export function OptionGroup({
    q,
    value,
    recommended,
    onChange,
    disabled = [],
    segmented = false,
    labelId,
}) {
    const multi = q.type === 'multi';
    const off = (o) => disabled.includes(o.value);
    const isOn = (o) => !off(o) && (multi ? (value || []).includes(o.value) : value === o.value);
    const isRec = (o) => (multi ? (recommended || []).includes(o.value) : recommended === o.value);

    const toggle = (o) =>
        onChange(
            (value || []).includes(o.value)
                ? value.filter((x) => x !== o.value)
                : [...(value || []), o.value]
        );

    const arrows = (e) => {
        const move = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
        if (!move) return;
        const radios = [...e.currentTarget.querySelectorAll('[role=radio]:not([disabled])')];
        const at = radios.indexOf(document.activeElement);
        if (at < 0) return;
        e.preventDefault();
        const next = radios[(at + move + radios.length) % radios.length];
        next.focus();
        next.click();
    };

    // roving tabindex: the selected radio (or the first enabled one) is the tab stop
    const stop = q.options.find(isOn) || q.options.find((o) => !off(o));

    return (
        <div
            role={multi ? 'group' : 'radiogroup'}
            aria-labelledby={labelId}
            onKeyDown={multi ? undefined : arrows}
            className={cn(
                'flex flex-wrap gap-1.5',
                segmented && 'bg-muted/50 w-fit gap-0.5 rounded-lg border p-0.5'
            )}
        >
            {q.options.map((o) => (
                <Option
                    key={o.value}
                    segmented={segmented}
                    active={isOn(o)}
                    disabled={off(o)}
                    recommended={isRec(o)}
                    later={o.runs === false}
                    onSelect={() => (multi ? toggle(o) : onChange(o.value))}
                    {...(multi
                        ? { 'aria-pressed': isOn(o) }
                        : { role: 'radio', 'aria-checked': isOn(o), tabIndex: o === stop ? 0 : -1 })}
                >
                    {o.label}
                </Option>
            ))}
        </div>
    );
}

/** `bool` question: a labelled switch with its On/Off state and the agent's note beside it. */
export function ToggleRow({ q, checked, recommended, onChange }) {
    const id = `q-${q.id}`;
    return (
        <div className="flex items-start justify-between gap-4">
            <label htmlFor={id} className="min-w-0 cursor-pointer text-sm font-medium">
                {q.label}
                {q.note && (
                    <span className="text-muted-foreground block text-xs font-normal">{q.note}</span>
                )}
            </label>
            <div className="flex shrink-0 items-center gap-2">
                <span className="text-muted-foreground w-6 text-right text-xs">
                    {checked ? 'On' : 'Off'}
                </span>
                <Switch id={id} checked={!!checked} onCheckedChange={onChange} />
                {checked === recommended && (
                    <span className="text-primary/80 hidden text-[10px] font-medium sm:inline">
                        Recommended
                    </span>
                )}
            </div>
        </div>
    );
}

const clamp = (n, q) => Math.min(q.max ?? 9, Math.max(q.min ?? 0, n));

/** `number` question: keeps what the user types, clamps on blur, never turns an empty field into 0. */
export function NumberField({ q, value, recommended, onChange }) {
    const [raw, setRaw] = useState(String(value ?? ''));

    const typed = (text) => {
        setRaw(text);
        const n = parseInt(text, 10);
        if (!Number.isNaN(n)) onChange(clamp(n, q));
    };
    const done = () => {
        const n = parseInt(raw, 10);
        const final = Number.isNaN(n) ? recommended : clamp(n, q);
        setRaw(String(final));
        onChange(final);
    };

    return (
        <div className="flex items-center gap-2">
            <Input
                type="number"
                inputMode="numeric"
                min={q.min}
                max={q.max}
                className="h-8 w-20"
                aria-label={q.label}
                value={raw}
                onChange={(e) => typed(e.target.value)}
                onBlur={done}
            />
            <span className="text-muted-foreground text-xs">
                {q.min ?? 0}–{q.max ?? 9} · recommended {recommended}
            </span>
        </div>
    );
}

/** A titled block of questions; `collapsible` ones show a chevron and open/close. */
export function Section({ icon: Icon, title, hint, badge, open = true, onToggle, children }) {
    const head = (
        <>
            <Icon className="text-primary size-4 shrink-0" />
            <span className="text-sm font-semibold">{title}</span>
            {badge && (
                <span className="bg-primary/15 text-primary rounded-full px-1.5 text-[10px]">
                    {badge}
                </span>
            )}
            {hint && <span className="text-muted-foreground truncate text-xs">{hint}</span>}
            {onToggle && (
                <ChevronDown
                    className={cn(
                        'text-muted-foreground ml-auto size-4 shrink-0 transition-transform',
                        open && 'rotate-180'
                    )}
                />
            )}
        </>
    );
    return (
        <section className="rounded-lg border">
            {onToggle ? (
                <button
                    type="button"
                    aria-expanded={open}
                    onClick={onToggle}
                    className="focus-visible:ring-ring/50 flex w-full items-center gap-2 rounded-lg px-4 py-3 text-left outline-none focus-visible:ring-[3px]"
                >
                    {head}
                </button>
            ) : (
                <div className="flex items-center gap-2 px-4 pt-3">{head}</div>
            )}
            {open && <div className="space-y-4 px-4 pt-3 pb-4">{children}</div>}
        </section>
    );
}
