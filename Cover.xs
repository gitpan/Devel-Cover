/*
 * Copyright 2001-2004, Paul Johnson (pjcj@cpan.org)
 *
 * This software is free.  It is licensed under the same terms as Perl itself.
 *
 * The latest version of this software should be available from my homepage:
 * http://www.pjcj.net
 *
 */

#ifdef __cplusplus
extern "C" {
#endif

#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#ifdef __cplusplus
}
#endif

#ifdef PERL_OBJECT
#define CALLOP this->*PL_op
#else
#define CALLOP *PL_op
#endif

#ifndef START_MY_CXT
/* No threads in 5.6 */
#define START_MY_CXT    static my_cxt_t my_cxt;
#define dMY_CXT_SV      dNOOP
#define dMY_CXT         dNOOP
#define MY_CXT_INIT     NOOP
#define MY_CXT          my_cxt

#define pMY_CXT         void
#define pMY_CXT_
#define _pMY_CXT
#define aMY_CXT
#define aMY_CXT_
#define _aMY_CXT
#endif

#define MY_CXT_KEY "Devel::Cover::_guts" XS_VERSION

#define PDEB(a) a
#define NDEB(a) ;
#define D PerlIO_printf
#define L Perl_debug_log
#define svdump(sv) do_sv_dump(0, L, (SV *)sv, 0, 10, 1, 0);

#define None       0x00000000
#define Statement  0x00000001
#define Branch     0x00000002
#define Condition  0x00000004
#define Subroutine 0x00000008
#define Path       0x00000010
#define Pod        0x00000020
#define Time       0x00000040
#define All        0xffffffff

#define CAN_PROFILE defined HAS_GETTIMEOFDAY || defined HAS_TIMES

struct unique    /* Well, we'll be fairly unlucky if it's not */
{
    OP *addr,
        op;
};

#define CH_SZ (sizeof(struct unique) + 1)

union sequence   /* Hack, hack, hackety hack. */
{
    struct unique op;
    char          ch[CH_SZ + 1];
};

typedef struct
{
    unsigned  covering;
    HV       *cover,
             *statements,
             *branches,
             *conditions,
#if CAN_PROFILE
             *times,
#endif
             *modules;
    AV       *ends;
    char      profiling_key[CH_SZ + 1];
    SV       *module;
    int       tid;
} my_cxt_t;

#ifdef USE_ITHREADS
static perl_mutex DC_mutex;
#endif

static HV  *Pending_conditionals,
           *Return_ops;
static int  tid;

START_MY_CXT

#define collecting(criterion) (MY_CXT.covering & (criterion))

#ifdef HAS_GETTIMEOFDAY

#ifdef __cplusplus
extern "C" {
#endif

#ifdef WIN32
#include <time.h>
#else
#include <sys/time.h>
#endif

#ifdef __cplusplus
}
#endif

static double get_elapsed()
{
#ifdef WIN32
    dTHX;
#endif
    struct timeval time;
    double   e;

    gettimeofday(&time, NULL);
    e = time.tv_sec * 1e6 + time.tv_usec;

    return e;
}

static double elapsed()
{
    static double p;
           double e, t;

    t = get_elapsed();
    e = t - p;
    p = t;

    return e;
}

#endif /* HAS_GETTIMEOFDAY */

#ifdef HAS_TIMES

#ifndef HZ
#  ifdef CLK_TCK
#    define HZ CLK_TCK
#  else
#    define HZ 60
#  endif
#endif

static int cpu()
{
#ifdef WIN32
    dTHX;
#endif
    static struct tms time;
    static int        utime = 0,
                      stime = 0;
    int               e;

#ifndef VMS
    (void)PerlProc_times(&time);
#else
    (void)PerlProc_times((tbuffer_t *)&time);
#endif

    e = time.tms_utime - utime + time.tms_stime - stime;
    utime = time.tms_utime;
    stime = time.tms_stime;

    return e / HZ;
}

#endif /* HAS_TIMES */

static char *get_key(OP *o)
{
    static union sequence uniq;
    int i;

    dTHX;

    uniq.op.addr          = o;
    uniq.op.op            = *o;
    uniq.op.op.op_ppaddr  = 0;  /* we mess with this field */
    uniq.ch[CH_SZ]        = 0;

    /* TODO - this shouldn't be necessary, should it?  It is a hack
     * because things are breaking with null chars in the key.  Replace
     * them with "-".
     */

    for (i = 0; i < CH_SZ; i++)
        /* for printing */
        /* if (uniq.ch[i] < 32 || uniq.ch[i] > 126) */
        if (!uniq.ch[i])
        {
            NDEB(D(L, "%d %d\n", i, uniq.ch[i]));
            uniq.ch[i] = '-';
        }

    NDEB(D(L, "0x%x <%s>\n", o, uniq.ch));
    return uniq.ch;
}

static void set_firsts_if_neeed(pTHX)
{
    SV *init = (SV *)get_cv("Devel::Cover::first_init", 0);
    SV *end  = (SV *)get_cv("Devel::Cover::first_end",  0);
    NDEB(svdump(end));
    if (PL_initav && av_len(PL_initav) >= 0)
    {
        SV **cv = av_fetch(PL_initav, 0, 0);
        if (*cv != init)
        {
            av_unshift(PL_initav, 1);
            av_store(PL_initav, 0, init);
        }
    }
    if (PL_endav && av_len(PL_endav) >= 0)
    {
        SV **cv = av_fetch(PL_endav, 0, 0);
        if (*cv != end)
        {
            av_unshift(PL_endav, 1);
            av_store(PL_endav, 0, end);
        }
    }
}

static void add_branch(pTHX_ OP *op, int br)
{
    dMY_CXT;
    AV  *branches;
    SV **count;
    int  c;
    SV **tmp = hv_fetch(MY_CXT.branches, get_key(op), CH_SZ, 1);

    if (SvROK(*tmp))
        branches = (AV *) SvRV(*tmp);
    else
    {
        *tmp = newRV_inc((SV*) (branches = newAV()));
        av_unshift(branches, 2);
    }

    count = av_fetch(branches, br, 1);
    c     = SvTRUE(*count) ? SvIV(*count) + 1 : 1;
    sv_setiv(*count, c);
    NDEB(D(L, "Adding branch making %d at %p\n", c, op));
}

static AV *get_conditional_array(pTHX_ OP *op)
{
    dMY_CXT;
    AV  *conds;
    SV **cref = hv_fetch(MY_CXT.conditions, get_key(op), CH_SZ, 1);

    if (SvROK(*cref))
        conds = (AV *) SvRV(*cref);
    else
        *cref = newRV_inc((SV*) (conds = newAV()));

    return conds;
}

static void set_conditional(pTHX_ OP *op, int cond, int value)
{
    /*
     * The conditional array comprises five elements:
     *
     * 0 - 1 iff we are in an xor and the first operand was true
     * 1 - not short circuited - second operand is false
     * 2 - not short circuited - second operand is true
     * 3 - short circuited, or for xor second operand is false
     * 4 - for xor second operand is true
     */

    SV **count = av_fetch(get_conditional_array(aTHX_ op), cond, 1);
    sv_setiv(*count, value);
    NDEB(D(L, "Setting %d conditional to %d at %p\n", cond, value, op));
}

static void add_conditional(pTHX_ OP *op, int cond)
{
    SV **count = av_fetch(get_conditional_array(aTHX_ op), cond, 1);
    int  c     = SvTRUE(*count) ? SvIV(*count) + 1 : 1;
    sv_setiv(*count, c);
    NDEB(D(L, "Adding %d conditional making %d at %p\n", cond, c, op));
}

static AV *get_conds(pTHX_ AV *conds)
{
    dMY_CXT;

    AV    *thrconds;
    HV    *threads;
    SV    *tid,
         **cref;
    char  *t;

    if (av_exists(conds, 2))
    {
        SV **cref = av_fetch(conds, 2, 0);
        threads = (HV *) *cref;
    }
    else
    {
        threads = newHV();
        HvSHAREKEYS_off(threads);
        av_store(conds, 2, (SV *)threads);
    }

    tid = newSViv(MY_CXT.tid);

    t = SvPV_nolen(tid);
    cref = hv_fetch(threads, t, strlen(t), 1);

    if (SvROK(*cref))
        thrconds = (AV *)SvRV(*cref);
    else
        *cref = newRV_inc((SV*) (thrconds = newAV()));

    return thrconds;
}

static void add_condition(pTHX_ SV *cond_ref, int value)
{
    int   final       = !value;
    AV   *conds       = (AV *)          SvRV(cond_ref);
    OP   *next        = (OP *)          SvIV(*av_fetch(conds, 0, 0));
    OP *(*addr)(pTHX) = (OP *(*)(pTHX)) SvIV(*av_fetch(conds, 1, 0));
    I32   i;

    if (!final && next != PL_op)
        croak("next (%p) does not match PL_op (%p)", next, PL_op);

#ifdef USE_ITHREADS
    i = 0;
    conds = get_conds(aTHX_ conds);
#else
    i = 2;
#endif
    NDEB(D(L, "Looking through %d conditionals\n", av_len(conds) - 1));
    for (; i <= av_len(conds); i++)
    {
        OP  *op    = (OP *) SvIV(*av_fetch(conds, i, 0));
        SV **count = av_fetch(get_conditional_array(aTHX_ op), 0, 1);
        int  type  = SvTRUE(*count) ? SvIV(*count) : 0;
        sv_setiv(*count, 0);

        /* Check if we have come from an xor with a true first op */
        if (final)     value =  1;
        if (type == 1) value += 2;

        NDEB(D(L, "Found %p: %d, %d\n", op, type, value));
        add_conditional(aTHX_ op, value);
    }

#ifdef USE_ITHREADS
    i = -1;
#else
    i = 1;
#endif
    while (av_len(conds) > i) av_pop(conds);

    NDEB(svdump(conds));
    NDEB(D(L, "addr is %p, next is %p, PL_op is %p, length is %d final is %d\n",
              addr, next, PL_op, av_len(conds), final));
    if (!final) next->op_ppaddr = addr;
}

static OP *get_condition(pTHX)
{
    dMY_CXT;

    SV **pc = hv_fetch(Pending_conditionals, get_key(PL_op), CH_SZ, 0);
    MUTEX_LOCK(&DC_mutex);

    if (pc && SvROK(*pc))
    {
        dSP;
        add_condition(aTHX_ *pc, SvTRUE(TOPs) ? 2 : 1);
    }
    else
    {
        PDEB(D(L, "All is lost, I know not where to go from %p, %p: %p\n",
                  PL_op, PL_op->op_targ, *pc));
        /* MUTEX_LOCK(&DC_mutex); */
        PDEB(svdump(Pending_conditionals));
        /* MUTEX_UNLOCK(&DC_mutex); */
        exit(1);
    }
    MUTEX_UNLOCK(&DC_mutex);

    return PL_op;
}

static void finalise_conditions(pTHX)
{
    /*
     * Our algorithm for conditions relies on ending up at a particular
     * op which we use to call get_condition().  It's possible that we
     * never get to that op; for example we might return out of a sub.
     * This causes us to lose coverage information.
     *
     * This function is called after the program has been run in order
     * to collect that lost information.
     */

    dMY_CXT;
    HE *e;

    MUTEX_LOCK(&DC_mutex);
    hv_iterinit(Pending_conditionals);

    while (e = hv_iternext(Pending_conditionals))
    {
        NDEB(D(L, "finalise_conditions\n"));
        add_condition(aTHX_ hv_iterval(Pending_conditionals, e), 0);
    }
    MUTEX_UNLOCK(&DC_mutex);
}

static void cover_cond(pTHX)
{
    dMY_CXT;
    if (collecting(Branch))
    {
        dSP;
        int val = SvTRUE(TOPs);
        add_branch(aTHX_ PL_op, !val);
    }
}

static void cover_logop(pTHX)
{
    /*
     * For OP_AND, if the first operand is false, we have short
     * circuited the second, otherwise the value of the and op is the
     * value of the second operand.
     *
     * For OP_OR, if the first operand is true, we have short circuited
     * the second, otherwise the value of the and op is the value of the
     * second operand.
     *
     * We check the value of the first operand by simply looking on the
     * stack.  To check the second operand it is necessary to note the
     * location of the next op after this logop.  When we get there, we
     * look at the stack and store the coverage information indexed to
     * this op.
     *
     * This scheme also works for OP_XOR with a small modification
     * because it doesn't short circuit.  See the comment below.
     *
     * To find out when we get to the next op we change the op_ppaddr to
     * point to get_condition(), which will do the necessary work and
     * then reset and run the original op_ppaddr.  We also store
     * information in the Pending_conditionals hash.  This is keyed on
     * the op and the value is an array, the first element of which is
     * the op we are messing with, the second element of which is the
     * op_ppaddr we overwrote, and the subsequent elements are the ops
     * about which we are collecting the condition coverage information.
     * Note that an op may be collecting condition coverage information
     * about a number of conditions.
     */

    dMY_CXT;

    if (!collecting(Condition))
        return;

    if (cLOGOP->op_first->op_type == OP_ITER)
    {
        /* loop - ignore it for now*/
    }
    else
    {
        dSP;
        int left_val = SvTRUE(TOPs);

        NDEB(D(L, "cover_logop [%s]\n", get_key(PL_op)));
        if (PL_op->op_type == OP_AND       &&  left_val ||
            PL_op->op_type == OP_ANDASSIGN &&  left_val ||
            PL_op->op_type == OP_OR        && !left_val ||
            PL_op->op_type == OP_ORASSIGN  && !left_val ||
            PL_op->op_type == OP_XOR)
        {
            /* no short circuit */

            OP *right = cLOGOP->op_first->op_sibling;
            NDEB(op_dump(right));

            if (right->op_type == OP_NEXT   ||
                right->op_type == OP_LAST   ||
                right->op_type == OP_REDO   ||
                right->op_type == OP_GOTO   ||
                right->op_type == OP_RETURN ||
                right->op_type == OP_DIE)
            {
                /*
                 * If the right side of the op is a branch, we don't
                 * care what its value is - it won't be returning one.
                 * We're just glad to be here, so we chalk up success.
                 */

                if (right->op_type == OP_DIE)
                {
                    NDEB(D(L, "Adding conditional [%s]\n", get_key(PL_op)));
                    NDEB(op_dump(PL_op));
                }
                add_conditional(aTHX_ PL_op, 2);
            }
            else
            {
                char *ch;
                AV   *conds;
                SV  **cref,
                     *cond;
                OP   *next;

                if (PL_op->op_type == OP_XOR && left_val)
                {
                    /*
                     * This is an xor.  It does not short circuit.  We
                     * have just executed the first op.  When we get to
                     * next we will have already done the xor, so we can
                     * work out what the value of the second op was.
                     *
                     * We set a flag in the first element of the array
                     * to say that we had a true value from the first
                     * op.
                     */

                    set_conditional(aTHX_ PL_op, 0, 1);
                }

                NDEB(op_dump(PL_op));

                next = PL_op->op_next;
                ch   = get_key(next);
                MUTEX_LOCK(&DC_mutex);
                cref = hv_fetch(Pending_conditionals, ch, CH_SZ, 1);

                if (SvROK(*cref))
                    conds = (AV *)SvRV(*cref);
                else
                    *cref = newRV_inc((SV*) (conds = newAV()));

                if (av_len(conds) < 0)
                {
                    av_push(conds, newSViv((IV) next));
                    av_push(conds, newSViv((IV) next->op_ppaddr));
                }

#ifdef USE_ITHREADS
                conds = get_conds(aTHX_ conds);
#endif

                cond = newSViv((IV) PL_op);
                av_push(conds, cond);

                NDEB(D(L, "Adding conditional %p to %p, making %d at %p\n",
                       next, next->op_targ, av_len(conds) - 1, PL_op));
                NDEB(svdump(Pending_conditionals));
                NDEB(op_dump(PL_op));
                NDEB(op_dump(next));

                next->op_ppaddr = get_condition;
                MUTEX_UNLOCK(&DC_mutex);
            }
        }
        else
        {
            /* short circuit */
            add_conditional(aTHX_ PL_op, 3);
        }
    }
}

#if CAN_PROFILE

static void cover_time(pTHX)
{
    dMY_CXT;
    SV **count;
    NV   c;

    if (collecting(Time))
    {
        /*
         * Profiling information is stored against MY_CXT.profiling_key,
         * the key for the op we have just run.
         */

        NDEB(D(L, "Cop at %p, op at %p\n", PL_curcop, PL_op));

        if (*MY_CXT.profiling_key)
        {
            count = hv_fetch(MY_CXT.times, MY_CXT.profiling_key, CH_SZ, 1);
            c     = (SvTRUE(*count) ? SvNV(*count) : 0) +
#if defined HAS_GETTIMEOFDAY
                    elapsed();
#else
                    cpu();
#endif
            sv_setnv(*count, c);
            NDEB(D(L, "Adding time: sum %f to <%s>\n", c, MY_CXT.profiling_key));
        }
        if (PL_op)
            strcpy(MY_CXT.profiling_key, get_key(PL_op));
        else
            *MY_CXT.profiling_key = 0;
    }
}

#endif

static int runops_cover(pTHX)
{
    SV   **count;
    IV     c;
    char  *ch;
    HV    *Files           = 0;
    int    collecting_here = 1;
    char  *lastfile        = 0;

    dMY_CXT;

    NDEB(D(L, "runops_cover\n"));

    MUTEX_LOCK(&DC_mutex);
    if (!Pending_conditionals)
    {
        Pending_conditionals = newHV();
        HvSHAREKEYS_off(Pending_conditionals);
    }
    if (!Return_ops)
    {
        Return_ops = newHV();
        HvSHAREKEYS_off(Return_ops);
    }
    MUTEX_UNLOCK(&DC_mutex);

    if (!MY_CXT.covering)
    {
        /* TODO - this probably leaks all over the place */

        SV **tmp;

        MY_CXT.cover      = newHV();
#ifdef USE_ITHREADS
        HvSHAREKEYS_off(MY_CXT.cover);
#endif

        tmp        = hv_fetch(MY_CXT.cover, "statement", 9, 1);
        MY_CXT.statements = newHV();
        *tmp       = newRV_inc((SV*) MY_CXT.statements);

        tmp        = hv_fetch(MY_CXT.cover, "branch",    6, 1);
        MY_CXT.branches   = newHV();
        *tmp       = newRV_inc((SV*) MY_CXT.branches);

        tmp        = hv_fetch(MY_CXT.cover, "condition", 9, 1);
        MY_CXT.conditions = newHV();
        *tmp       = newRV_inc((SV*) MY_CXT.conditions);

#if CAN_PROFILE
        tmp        = hv_fetch(MY_CXT.cover, "time",      4, 1);
        MY_CXT.times      = newHV();
        *tmp       = newRV_inc((SV*) MY_CXT.times);
#endif

        tmp        = hv_fetch(MY_CXT.cover, "module",    6, 1);
        MY_CXT.modules    = newHV();
        *tmp       = newRV_inc((SV*) MY_CXT.modules);

#ifdef USE_ITHREADS
        HvSHAREKEYS_off(MY_CXT.statements);
        HvSHAREKEYS_off(MY_CXT.branches);
        HvSHAREKEYS_off(MY_CXT.conditions);
#if CAN_PROFILE
        HvSHAREKEYS_off(MY_CXT.times);
#endif
        HvSHAREKEYS_off(MY_CXT.modules);
#endif

        *MY_CXT.profiling_key = 0;

        MY_CXT.module = newSVpv("", 0);

        MY_CXT.covering = All;

        MY_CXT.tid = tid++;
    }

#if defined HAS_GETTIMEOFDAY
    elapsed();
#elif defined HAS_TIMES
    cpu();
#endif

    for (;;)
    {
        NDEB(D(L, "running func %p\n", PL_op->op_ppaddr));
        NDEB(D(L, "op is %s\n", OP_NAME(PL_op)));

        if (!MY_CXT.covering)
            goto call_fptr;

        /* Nothing to collect when we've hijacked the ppaddr */
        if (PL_op->op_ppaddr == get_condition)
            goto call_fptr;

        /* Check to see whether we are interested in this file */

        if (PL_op->op_type == OP_NEXTSTATE)
        {
            char *file = CopFILE(cCOP);
            NDEB(D(L, "File: %s:%ld\n", file, CopLINE(cCOP)));
            if (file && (!lastfile || lastfile && strNE(lastfile, file)))
            {
                if (!Files)
                    Files = get_hv("Devel::Cover::Files", FALSE);
                if (Files)
                {
                    SV **f = hv_fetch(Files, file, strlen(file), 0);
                    collecting_here = f ? SvIV(*f) : 1;
                    NDEB(D(L, "File: %s:%ld [%d]\n",
                              file, CopLINE(cCOP), collecting_here));
                }
                lastfile = file;
            }
#if (PERL_VERSION > 6)
            if (SvTRUE(MY_CXT.module))
            {
                STRLEN mlen,
                       flen = strlen(file);
                char  *m    = SvPV(MY_CXT.module, mlen);
                if (flen >= mlen && strnEQ(m, file + flen - mlen, mlen))
                {
                    SV **dir = hv_fetch(MY_CXT.modules, file, strlen(file), 1);
                    if (!SvROK(*dir))
                    {
                        SV *cwd = newSV(0);
                        AV *d   = newAV();
                        *dir = newRV_inc((SV*) d);
                        av_push(d, newSVsv(MY_CXT.module));
                        if (getcwd_sv(cwd))
                        {
                            av_push(d, newSVsv(cwd));
                            NDEB(D(L, "require %s as %s from %s\n",
                                      m, file, SvPV_nolen(cwd)));
                        }
                    }
                }
                sv_setpv(MY_CXT.module, "");
                set_firsts_if_neeed(aTHX);
            }
#endif
        }
        else if (collecting_here && PL_op->op_type == OP_ENTERSUB)
        {
            /* If we are jumping somewhere we might not be collecting
             * coverage there, so store where we will be coming back to
             * so we can turn on coverage straight away.  We need to
             * store more than one return op because a non collecting
             * sub may call back to a collecting sub.
             */
            hv_fetch(Return_ops, get_key(PL_op->op_next), CH_SZ, 1);
            NDEB(D(L, "adding return op %p\n", PL_op->op_next));
        }

        if (!collecting_here)
        {
#if CAN_PROFILE
            cover_time(aTHX);
            *MY_CXT.profiling_key = 0;
#endif
            NDEB(D(L, "op %p is %s\n", PL_op, OP_NAME(PL_op)));
            if (hv_exists(Return_ops, get_key(PL_op), CH_SZ))
                collecting_here = 1;
            else
                goto call_fptr;
        }

        /*
         * We are about the run the op PL_op, so we'll collect
         * information for it now.
         */

        switch (PL_op->op_type)
        {
            case OP_SETSTATE:
            case OP_NEXTSTATE:
            case OP_DBSTATE:
            {
#if CAN_PROFILE
                cover_time(aTHX);
#endif
                if (collecting(Statement))
                {
                    ch    = get_key(PL_op);
                    count = hv_fetch(MY_CXT.statements, ch, CH_SZ, 1);
                    c     = SvTRUE(*count) ? SvIV(*count) + 1 : 1;
                    sv_setiv(*count, c);
                    NDEB(op_dump(PL_op));
                }
                break;
            }

            case OP_COND_EXPR:
            {
                cover_cond(aTHX);
                break;
            }

            case OP_AND:
            case OP_OR:
            case OP_ANDASSIGN:
            case OP_ORASSIGN:
            case OP_XOR:
            {
                cover_logop(aTHX);
                break;
            }

            case OP_REQUIRE:
            {
                dSP;
                sv_setsv(MY_CXT.module, TOPs);
                NDEB(D(L, "require %s\n", SvPV_nolen(MY_CXT.module)));
                break;
            }

            default:
                ;  /* IBM's xlC compiler on AIX is very picky */
        }

        call_fptr:
        if (!(PL_op = CALL_FPTR(PL_op->op_ppaddr)(aTHX)))
        {
#if CAN_PROFILE
            cover_time(aTHX);
#endif
            break;
        }

        PERL_ASYNC_CHECK();
    }

    TAINT_NOT;
    return 0;
}

static int runops_orig(pTHX)
{
    NDEB(D(L, "runops_orig\n"));

    while ((PL_op = CALL_FPTR(PL_op->op_ppaddr)(aTHX)))
    {
        PERL_ASYNC_CHECK();
    }

    TAINT_NOT;
    return 0;
}

static char *svclassnames[] =
{
    "B::NULL",
    "B::IV",
    "B::NV",
    "B::RV",
    "B::PV",
    "B::PVIV",
    "B::PVNV",
    "B::PVMG",
    "B::BM",
    "B::GV",
    "B::PVLV",
    "B::AV",
    "B::HV",
    "B::CV",
    "B::FM",
    "B::IO",
};

static SV *make_sv_object(pTHX_ SV *arg, SV *sv)
{
    IV    iv;
    char *type;
    dMY_CXT;

    iv = PTR2IV(sv);
    type = svclassnames[SvTYPE(sv)];
    sv_setiv(newSVrv(arg, type), iv);
    return arg;
}


typedef OP *B__OP;
typedef AV *B__AV;


MODULE = Devel::Cover PACKAGE = Devel::Cover

PROTOTYPES: ENABLE

void
set_criteria(flag)
        unsigned flag
    PREINIT:
        dMY_CXT;
    PPCODE:
        /* fprintf(stderr, "Cover set to %d\n", flag); */
        PL_runops = (MY_CXT.covering = flag) ? runops_cover : runops_orig;

void
add_criteria(flag)
        unsigned flag
    PREINIT:
        dMY_CXT;
    PPCODE:
        PL_runops = (MY_CXT.covering |= flag) ? runops_cover : runops_orig;

void
remove_criteria(flag)
        unsigned flag
    PREINIT:
        dMY_CXT;
    PPCODE:
        PL_runops = (MY_CXT.covering &= ~flag) ? runops_cover : runops_orig;

unsigned
get_criteria()
    PREINIT:
        dMY_CXT;
    CODE:
        RETVAL = MY_CXT.covering;
    OUTPUT:
        RETVAL

unsigned
coverage_none()
    CODE:
        RETVAL = None;
    OUTPUT:
        RETVAL

unsigned
coverage_statement()
    CODE:
        RETVAL = Statement;
    OUTPUT:
        RETVAL

unsigned
coverage_branch()
    CODE:
        RETVAL = Branch;
    OUTPUT:
        RETVAL

unsigned
coverage_condition()
    CODE:
        RETVAL = Condition;
    OUTPUT:
        RETVAL

unsigned
coverage_subroutine()
    CODE:
        RETVAL = Subroutine;
    OUTPUT:
        RETVAL

unsigned
coverage_path()
    CODE:
        RETVAL = Path;
    OUTPUT:
        RETVAL

unsigned
coverage_pod()
    CODE:
        RETVAL = Pod;
    OUTPUT:
        RETVAL

unsigned
coverage_time()
    CODE:
        RETVAL = Time;
    OUTPUT:
        RETVAL

unsigned
coverage_all()
    CODE:
        RETVAL = All;
    OUTPUT:
        RETVAL

double
get_elapsed()
    CODE:
#ifdef HAS_GETTIMEOFDAY
        RETVAL = get_elapsed();
#else
        RETVAL = 0;
#endif
    OUTPUT:
        RETVAL

SV *
coverage(final)
        unsigned final
    PREINIT:
        dMY_CXT;
    CODE:
        NDEB(D(L, "Getting coverage %d\n", final));
        if (final) finalise_conditions(aTHX);
        ST(0) = sv_newmortal();
        if (MY_CXT.cover)
            sv_setsv(ST(0), newRV_inc((SV*) MY_CXT.cover));
        else
            ST(0) = &PL_sv_undef;

char *
get_key(o)
        B::OP o
    CODE:
        RETVAL = get_key(o);
    OUTPUT:
        RETVAL

void
set_first_init_and_end()
    PPCODE:
        set_firsts_if_neeed(aTHX);

void
collect_inits()
    PREINIT:
        dMY_CXT;
    PPCODE:
        int i;
        NDEB(svdump(end));
        if (!MY_CXT.ends) MY_CXT.ends = newAV();
        if (PL_initav)
            for (i = 0; i <= av_len(PL_initav); i++)
            {
                SV **cv = av_fetch(PL_initav, i, 0);
                SvREFCNT_inc(*cv);
                av_push(MY_CXT.ends, *cv);
            }

void
set_last_end()
    PREINIT:
        dMY_CXT;
    PPCODE:
        int i;
        SV *end = (SV *)get_cv("last_end", 0);
        av_push(PL_endav, end);
        NDEB(svdump(end));
        if (!MY_CXT.ends) MY_CXT.ends = newAV();
        if (PL_endav)
            for (i = 0; i <= av_len(PL_endav); i++)
            {
                SV **cv = av_fetch(PL_endav, i, 0);
                SvREFCNT_inc(*cv);
                av_push(MY_CXT.ends, *cv);
            }

B::AV
get_ends()
    PREINIT:
        dMY_CXT;
    CODE:
        RETVAL = MY_CXT.ends;
    OUTPUT:
        RETVAL


BOOT:
    {
        MY_CXT_INIT;
    }
#ifdef USE_ITHREADS
    MUTEX_INIT(&DC_mutex);
#endif
    PL_runops    = runops_cover;
#if PERL_VERSION > 6
    PL_savebegin = TRUE;
#endif
