import { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import {
    ChevronDown,
    ClipboardList,
    Loader2,
    RotateCcw,
    Rocket,
    Search,
    Send,
    Settings2,
    ShieldCheck,
} from 'lucide-react';
import { cn } from '@/core/lib/utils';
import { Button } from '@/shared/ui/button';
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
} from '@/shared/ui/dialog';
import usePipelineStore from '../store/usePipelineStore';
import { NumberField, OptionGroup, Section, ToggleRow, sameAnswer } from './questionnaire/controls';

// Presentation only: which block a question lives in. Ids, values and order sent to the API never change,
// and a question that is not listed here (added to devops_flow.yml later) lands in "Advanced".
const ESSENTIAL = ['deploy_as', 'tests', 'uat', 'approval_before_uat'];
const SECURITY = ['sast_tool', 'sca_tool', 'secrets_tool'];

const draftKey = (taskId) => `cip-q-${taskId}`;
const readDraft = (taskId) => {
    try {
        return JSON.parse(sessionStorage.getItem(draftKey(taskId)) || 'null');
    } catch {
        return null;
    }
};
const writeDraft = (taskId, values) => {
    try {
        if (values) sessionStorage.setItem(draftKey(taskId), JSON.stringify(values));
        else sessionStorage.removeItem(draftKey(taskId));
    } catch {
        /* storage blocked – the form still works */
    }
};

/** Recommended values, overlaid with a saved draft of the same shape (so a refresh keeps the edits). */
function initialAnswers(taskId, recommended) {
    const draft = readDraft(taskId) || {};
    return Object.fromEntries(
        Object.entries(recommended).map(([id, rec]) => {
            const v = draft[id];
            const fits =
                v !== undefined && Array.isArray(v) === Array.isArray(rec) && typeof v === typeof rec;
            return [id, fits ? v : rec];
        })
    );
}

/** One line about the code: "2 components · Python, React · no Dockerfile". */
function detectedSummary(d) {
    const comps = d.components || [];
    const langs = [...new Set(comps.map((c) => c.framework || c.language).filter(Boolean))];
    return [
        `${comps.length} component${comps.length === 1 ? '' : 's'}`,
        langs.join(', '),
        d.dockerfiles?.length ? 'Dockerfile found' : 'no Dockerfile (DevOps writes one)',
        d.ci_files?.length ? `CI: ${d.ci_files.length} file(s)` : '',
    ]
        .filter(Boolean)
        .join(' · ');
}

function Detected({ d }) {
    const [open, setOpen] = useState(false);
    return (
        <div className="bg-muted/40 rounded-lg border text-sm">
            <button
                type="button"
                aria-expanded={open}
                onClick={() => setOpen((o) => !o)}
                className="focus-visible:ring-ring/50 flex w-full items-center gap-2 rounded-lg px-4 py-2.5 text-left outline-none focus-visible:ring-[3px]"
            >
                <Search className="text-primary size-4 shrink-0" />
                <span className="font-semibold">Found in the code</span>
                <span className="text-muted-foreground truncate text-xs">{detectedSummary(d)}</span>
                <ChevronDown
                    className={cn(
                        'text-muted-foreground ml-auto size-4 shrink-0 transition-transform',
                        open && 'rotate-180'
                    )}
                />
            </button>
            {open && (
                <div className="grid gap-x-6 gap-y-1 border-t px-4 py-3 text-xs md:grid-cols-2">
                    {(d.components || []).map((c, i) => (
                        <div key={`${c.name}-${i}`}>
                            <b>{c.name}</b> – {c.language} {c.framework} ({c.kind})
                            {c.deployable ? ' · server' : ''}
                            {c.has_tests ? ' · has tests' : ' · no tests'}
                        </div>
                    ))}
                    <div>
                        Dockerfiles:{' '}
                        {d.dockerfiles?.length ? d.dockerfiles.join(', ') : 'none (DevOps writes one)'}
                    </div>
                    <div>CI files: {d.ci_files?.length ? d.ci_files.join(', ') : 'none'}</div>
                    <div>
                        Kubernetes files: {d.kubernetes_files?.length || 0} · Terraform files:{' '}
                        {d.terraform_files?.length || 0}
                    </div>
                </div>
            )}
        </div>
    );
}

/** Guided flow – the run waits here: what the agent learned from the code + the questions it could not answer. */
export default function QuestionnaireCard() {
    const run = usePipelineStore((s) => s.run);
    const resume = usePipelineStore((s) => s.resume);
    const pending = run?.pending;
    const taskId = run?.task_id;
    const [sending, setSending] = useState(false);
    const [scanOpen, setScanOpen] = useState(null); // null = follow "customized"
    const [advOpen, setAdvOpen] = useState(null);
    const [resetCount, setResetCount] = useState(0);
    const [draft, setDraft] = useState({ key: '', values: {} });

    const isOpen = run?.status === 'WAITING_INPUT' && pending?.type === 'questionnaire';
    const questions = useMemo(() => pending?.questions || [], [pending]);
    const recommended = useMemo(
        () => Object.fromEntries(questions.map((q) => [q.id, q.value])),
        [questions]
    );
    // the answers are re-seeded only for another run or another set of questions – not on every reload of the run
    const seedKey = `${taskId}:${questions.map((q) => q.id).join(',')}`;
    const initial = useMemo(
        () => (isOpen ? initialAnswers(taskId, recommended) : {}),
        [seedKey, isOpen] // eslint-disable-line react-hooks/exhaustive-deps
    );
    const answers = draft.key === seedKey ? draft.values : initial;

    useEffect(() => {
        if (isOpen && draft.key === seedKey) writeDraft(taskId, draft.values);
    }, [draft, seedKey, isOpen, taskId]);

    if (!isOpen) return null;

    const byId = Object.fromEntries(questions.map((q) => [q.id, q]));
    const set = (id, v) => setDraft({ key: seedKey, values: { ...answers, [id]: v } });
    const changed = questions.filter((q) => !sameAnswer(answers[q.id], recommended[q.id]));
    const container = answers.deploy_as === 'container';

    const advanced = questions.filter((q) => ![...ESSENTIAL, ...SECURITY].includes(q.id));
    const advancedShown = advanced.filter((q) => q.id !== 'registry' || container);
    const customScan = SECURITY.some((id) => byId[id] && !sameAnswer(answers[id], recommended[id]));
    const customAdv = advanced.some((q) => !sameAnswer(answers[q.id], recommended[q.id]));

    const reset = () => {
        setDraft({ key: seedKey, values: { ...recommended } });
        setResetCount((n) => n + 1);
    };

    const submit = async () => {
        setSending(true);
        try {
            // every question is sent – also the hidden ones – and numbers always as an int in range
            const payload = Object.fromEntries(
                questions.map((q) => {
                    let v = answers[q.id];
                    if (q.type === 'number') {
                        v = parseInt(v, 10);
                        v = Number.isNaN(v) ? recommended[q.id] : Math.min(q.max ?? 9, Math.max(q.min ?? 0, v));
                    }
                    return [q.id, v];
                })
            );
            await resume('answers', payload);
            writeDraft(taskId, null);
            toast.success('Answers sent – deriving the pipeline');
        } catch (e) {
            if (/not waiting/i.test(e.message || '')) {
                toast.error('This run was already resumed – refreshing');
                writeDraft(taskId, null);
                usePipelineStore.getState().loadRun(taskId).catch(() => {});
            } else toast.error(e.message);
        } finally {
            setSending(false);
        }
    };

    const field = (q) => {
        const id = `ql-${q.id}`;
        const key = `${q.id}-${resetCount}`; // a reset remounts the number field so it shows the recommended value
        const common = { value: answers[q.id], recommended: recommended[q.id] };
        if (q.type === 'bool')
            return (
                <ToggleRow
                    key={key}
                    q={q}
                    checked={answers[q.id]}
                    recommended={recommended[q.id]}
                    onChange={(v) => set(q.id, v)}
                />
            );
        let control = null;
        if (q.type === 'single' || q.type === 'multi')
            control = (
                <OptionGroup
                    {...common}
                    q={q}
                    labelId={id}
                    segmented={q.id === 'deploy_as'}
                    disabled={q.id === 'tests' && !container ? ['functional', 'ui'] : []}
                    onChange={(v) => set(q.id, v)}
                />
            );
        else if (q.type === 'number')
            control = <NumberField {...common} q={q} onChange={(v) => set(q.id, v)} />;
        if (!control) return null;
        return (
            <div key={key} className="space-y-1.5">
                <div id={id} className="text-sm font-medium">
                    {q.label}
                    {q.note && (
                        <div className="text-muted-foreground text-xs font-normal">{q.note}</div>
                    )}
                    {q.id === 'tests' && !container && (
                        <div className="text-muted-foreground text-xs font-normal">
                            Functional and UI tests need a deployed container.
                        </div>
                    )}
                </div>
                {control}
            </div>
        );
    };

    const essentials = ESSENTIAL.map((id) => byId[id]).filter(Boolean).filter((q) => {
        if (q.id === 'uat') return container;
        if (q.id === 'approval_before_uat') return container && answers.uat;
        return true;
    });
    const security = SECURITY.map((id) => byId[id]).filter(Boolean);
    const scanVisible = scanOpen ?? customScan;

    return (
        <Dialog open={isOpen}>
            <DialogContent
                showCloseButton={false}
                className="max-h-[90vh] gap-0 overflow-hidden p-0 sm:max-w-3xl"
            >
                <DialogHeader className="px-6 pt-6 pb-3">
                    <DialogTitle className="flex items-center gap-2">
                        <ClipboardList className="text-primary size-5" /> A few answers to build your
                        pipeline
                    </DialogTitle>
                    <DialogDescription>
                        Everything is pre-filled from your code. Change only what you need – the
                        recommended choice is marked.
                    </DialogDescription>
                </DialogHeader>

                <div className="flex-1 space-y-3 overflow-y-auto px-6 pb-4">
                    <Detected d={pending.detected || {}} />

                    <Section icon={Rocket} title="Delivery and tests">
                        {essentials.map((q) => field(q))}
                    </Section>

                    {security.length > 0 && (
                        <Section
                            icon={ShieldCheck}
                            title="Security scanners"
                            hint={
                                customScan
                                    ? 'Customized'
                                    : 'Auto-select the best scanners (recommended)'
                            }
                            open={scanVisible}
                            onToggle={() => setScanOpen(!scanVisible)}
                        >
                            {security.map((q) => field(q))}
                        </Section>
                    )}

                    {advanced.length > 0 && (
                        <Section
                            icon={Settings2}
                            title="Advanced and future targets"
                            hint="options marked “recorded only” are saved but run locally for now"
                            badge={customAdv ? 'changed' : null}
                            open={advOpen ?? customAdv}
                            onToggle={() => setAdvOpen(!(advOpen ?? customAdv))}
                        >
                            {advancedShown.map((q) => field(q))}
                        </Section>
                    )}
                </div>

                <div className="bg-background flex flex-wrap items-center gap-3 border-t px-6 py-3">
                    <span className="text-muted-foreground text-xs">
                        {changed.length
                            ? `${changed.length} changed from recommended`
                            : 'Using the recommended setup'}
                    </span>
                    <div className="ml-auto flex items-center gap-2">
                        <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            className="gap-1.5"
                            onClick={reset}
                            disabled={sending || !changed.length}
                        >
                            <RotateCcw className="size-3.5" /> Reset to recommended
                        </Button>
                        <Button onClick={submit} disabled={sending} className="gap-2">
                            {sending ? (
                                <Loader2 className="size-4 animate-spin" />
                            ) : (
                                <Send className="size-4" />
                            )}{' '}
                            Derive the pipeline and run it
                        </Button>
                    </div>
                </div>
            </DialogContent>
        </Dialog>
    );
}
