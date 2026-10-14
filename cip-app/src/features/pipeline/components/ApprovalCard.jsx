import { useState } from 'react';
import toast from 'react-hot-toast';
import { Check, ShieldQuestion, X } from 'lucide-react';
import { Button } from '@/shared/ui/button';
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
} from '@/shared/ui/dialog';
import { Input } from '@/shared/ui/input';
import StatusBadge from '@/shared/components/StatusBadge';
import usePipelineStore from '../store/usePipelineStore';

/** Security review: the gate checks, findings per scanner and the most serious findings. */
function SecuritySummary({ sm }) {
    return (
        <div className="space-y-2">
            <div className="flex flex-wrap gap-2">
                <StatusBadge
                    status={sm.gate_passed ? 'passed' : 'failed'}
                    label={`security gate: ${sm.gate_passed ? 'PASS' : 'FAIL'}`}
                />
                {(sm.checks || [])
                    .filter((c) => !c.passed)
                    .map((c) => (
                        <StatusBadge
                            key={c.name}
                            status="failed"
                            label={`${c.name} = ${c.actual} (needs ${c.required})`}
                        />
                    ))}
            </div>
            {Object.keys(sm.per_scanner || {}).length > 0 && (
                <div className="text-muted-foreground text-xs">
                    {Object.entries(sm.per_scanner)
                        .map(
                            ([name, c]) =>
                                `${name}: ${c.CRITICAL} critical · ${c.HIGH} high · ${c.MEDIUM} medium`
                        )
                        .join('   |   ')}
                </div>
            )}
            {sm.top?.length > 0 && (
                <ul className="space-y-0.5 text-xs">
                    {sm.top.map((f, i) => (
                        <li key={i}>
                            <span className="font-semibold">{f.severity}</span> · {f.scanner} ·{' '}
                            {f.title}{' '}
                            <span className="text-muted-foreground font-mono">
                                {f.file}
                                {f.line ? `:${f.line}` : ''}
                            </span>
                        </li>
                    ))}
                </ul>
            )}
        </div>
    );
}

/** Human in the loop: the run waits until a reviewer approves or rejects –
 *  the security reports (after the scans, both flows) or the UAT deploy (guided flow). */
export default function ApprovalCard() {
    const run = usePipelineStore((s) => s.run);
    const resume = usePipelineStore((s) => s.resume);
    const [by, setBy] = useState('');
    const [comment, setComment] = useState('');
    const [sending, setSending] = useState(false);
    const type = run?.pending?.type;

    const isOpen =
        run?.status === 'WAITING_APPROVAL' && ['approval', 'security_review'].includes(type);

    if (!isOpen) return null;
    const security = type === 'security_review';
    const sm = run.pending.summary || {};

    const decide = async (decision) => {
        setSending(true);
        try {
            await resume('approval', { decision, by: by || 'reviewer', comment });
            toast.success(
                security
                    ? decision === 'approve'
                        ? 'Approved – the pipeline continues'
                        : 'Rejected – the pipeline stops and writes its report'
                    : decision === 'approve'
                      ? 'Approved – deploying to UAT'
                      : 'Rejected – UAT deploy skipped'
            );
        } catch (e) {
            toast.error(e.message);
        } finally {
            setSending(false);
        }
    };

    return (
        <Dialog open={isOpen}>
            <DialogContent
                showCloseButton={false}
                className="max-h-[85vh] overflow-y-auto sm:max-w-3xl"
            >
                <DialogHeader>
                    <DialogTitle className="flex items-center gap-2">
                        <ShieldQuestion className="size-5 text-amber-500" />
                        {security
                            ? 'HITL – review the security reports'
                            : `Approval needed before ${String(run.pending.target).toUpperCase()}`}
                    </DialogTitle>
                    <DialogDescription>
                        {security
                            ? 'The scans are done. Review the findings (click a scanner in the pipeline for its report), then approve to continue or reject to stop the pipeline.'
                            : 'Review the stage reports below, then approve or reject the deployment.'}
                    </DialogDescription>
                </DialogHeader>
                <div className="space-y-3 text-sm">
                    {security && <SecuritySummary sm={sm} />}
                    <div className="flex flex-wrap gap-2">
                        {Object.entries(sm.gates || {}).map(([k, ok]) => (
                            <StatusBadge
                                key={k}
                                status={ok ? 'passed' : 'failed'}
                                label={`${k}: ${ok ? 'PASS' : 'FAIL'}`}
                            />
                        ))}
                        {Object.entries(sm.findings || {}).map(([k, n]) => (
                            <StatusBadge
                                key={k}
                                status={n ? 'warning' : 'passed'}
                                label={`${n} ${k.toLowerCase()}`}
                            />
                        ))}
                    </div>
                    {sm.failed_steps?.length > 0 && (
                        <div className="text-red-500">
                            Failed steps: {sm.failed_steps.join(', ')}
                        </div>
                    )}
                    {Object.keys(sm.released || {}).length > 0 && (
                        <div className="text-muted-foreground text-xs">
                            Released:{' '}
                            {Object.entries(sm.released)
                                .map(([k, v]) => `${k} → ${v}`)
                                .join(' · ')}
                        </div>
                    )}
                    <div className="grid gap-2 md:grid-cols-[200px_1fr]">
                        <Input
                            placeholder="Your name"
                            value={by}
                            onChange={(e) => setBy(e.target.value)}
                        />
                        <Input
                            placeholder="Comment (optional)"
                            value={comment}
                            onChange={(e) => setComment(e.target.value)}
                        />
                    </div>
                    <div className="flex gap-2">
                        <Button
                            onClick={() => decide('approve')}
                            disabled={sending}
                            className="gap-2"
                        >
                            <Check className="size-4" />{' '}
                            {security ? 'Approve – continue the pipeline' : 'Approve UAT deploy'}
                        </Button>
                        <Button
                            variant="outline"
                            onClick={() => decide('reject')}
                            disabled={sending}
                            className="gap-2"
                        >
                            <X className="size-4" />{' '}
                            {security ? 'Reject – stop the pipeline' : 'Reject'}
                        </Button>
                    </div>
                </div>
            </DialogContent>
        </Dialog>
    );
}
