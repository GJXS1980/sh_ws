.PHONY: test syntax clean
syntax:
	find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
	python3 -m compileall -q modules install tests

test:
	bash tests/run.sh

clean:
	find . -type d -name __pycache__ -prune -exec rm -r -- {} +
	find . -type f -name '*.pyc' -delete
