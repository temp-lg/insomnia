The Insomnia Programming Language
=================================

Insomnia is a strongly typed probabilistic programming language.

Slogans:

* A *model* is a distribution over *modules*.
* *Model sealing* is marginalization.

Documentation
-------------

There is a (fairly sparse at this point) [Insomnia User's Guide](docs/guide.md)

Some examples are in pretty good shape.  See:

* [normal.ism](examples/normal.ism)
* [tugOfWar.ism](examples/tugOfWar.ism)

Building from source - installation instructions
------------------------------------------------

### Cabal sandbox workflow

1. Make sure you have a recent GHC (7.6+, but 7.8+ is better)

2. Make sure you have a recent cabal with support for sandboxes

        $ cabal --version
        cabal-install version 1.20.0.3
        using version 1.20.0.0 of the Cabal library

3. Setup a cabal sandbox in the current directory.

        $ cabal sandbox init

    This creates a sandbox for insomnia in the current directory.

4. Run the usual cabal build

        $ cabal install --enable-tests --only-dependencies
        $ cabal configure --enable-tests
        $ cabal build
        $ cabal test

    Note that installing the upstream dependencies may take a significant
    amount of time.

5. Try an example in the interpreter

        $ dist/build/insomnia/insomnia examples/query.ism

    The expected output is a message that the file typechecked okay,
    followed by a pretty-printing of the source code, followed by the
    state of the type unification algorithm at the end of typechecking,
    followed by the elaboration to core FΩ, followed by something like:
    

        --------------------✂✄--------------------
        Typechecking FΩ
        FOmega type is: 
        {M : Dist {x : {val : Int}}}
        
        
        --------------------✂✄--------------------
        Running FΩ
        pack
        inj Cons
        {#0 = {x = {val = 1}},
        ... several dozen more lines of output ...
        

    (Sorry, the backend is a work in progress)

### Building HTML and PDF versions of the User's guide:

The documentation is in Markdown format. You will need [Pandoc](http://pandoc.org/) to build HTML and PDF versions.

    make -C docs

Compiler
--------

There is an insomnia compiler, called `insomniac` that outputs [Gamble](https://github.com/rmculpepper/gamble) code.
It's also a work in progress.

```
    $ dist/build/insomniac/insomniac examples/evalSimplest.ism
```
