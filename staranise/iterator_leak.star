# This file defines the iterator_leak analyzer, which checks for
# calls to the starlark.Iterator function (or Iterator.Iterate method)
# without a corresponding call to Done.
#
# It is written in Starlark using Stargo,
# as a proof-of-concept of dynamically loaded checkers.

load(
    "go",
    analysis = "golang.org/x/tools/go/analysis",
    ast = "go/ast",
    inspect = "golang.org/x/tools/go/analysis/passes/inspect",
)

def run(pass_):
    # Short cut: inspect only packages that directly import starlark.Value.
    if "go.starlark.net/starlark" not in [p.Path() for p in pass_.Pkg.Imports()]:
        return None, None

    inspector = pass_.ResultOf[inspect.Analyzer]

    # types
    assignStmt = *ast.AssignStmt
    selectorExpr = *ast.SelectorExpr
    callExpr = *ast.CallExpr
    astIdent = *ast.Ident

    iterators = {}  # maps iterator *types.Var to Iterate *ast.CallExpr

    def visit(n):
        t = go.typeof(n)
        if (t == assignStmt and
            len(n.Lhs) == 1 and
            len(n.Rhs) == 1 and
            go.typeof(n.Rhs[0]) == callExpr and
            go.typeof(n.Rhs[0].Fun) == selectorExpr and
            n.Rhs[0].Fun.Sel.Name == "Iterate" and
            go.typeof(n.Lhs[0]) == astIdent):
            # n is one of:
            #   iter = value.Iterate()
            #   iter = starlark.Iterate(...)
            # TODO: check that it's our Iterate method/func and not some other.
            var = pass_.TypesInfo.ObjectOf(n.Lhs[0])
            iterators[var] = n.Rhs[0]

        elif (t == callExpr and
              go.typeof(n.Fun) == selectorExpr and
              n.Fun.Sel.Name == "Done" and
              go.typeof(n.Fun.X) == astIdent):
            # n is iter.Done().
            var = pass_.TypesInfo.ObjectOf(n.Fun.X)
            iterators[var] = None

        return

    inspector.Preorder((assignStmt(), callExpr()), visit)

    # Report the leaked iterators.
    for var, call in iterators.items():
        if call:
            pass_.Reportf(call.Lparen, "iterator leak (missing %s.Done() call)", var.Name())

    return None, None

# TODO: go/analysis doesn't know that our run may panic a starlark.EvalError.
# How can we make it display the stack?  Should we wrap run ourselves?

# iterator_leak analyzer
iterator_leak = go.new(analysis.Analyzer)
iterator_leak.Name = "iterator_leak"
iterator_leak.Doc = "report calls to starlark.Iterator without a matching Done"
iterator_leak.Run = run
iterator_leak.Requires = [inspect.Analyzer]
